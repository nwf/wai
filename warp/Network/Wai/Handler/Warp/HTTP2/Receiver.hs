{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Network.Wai.Handler.Warp.HTTP2.Receiver (frameReceiver) where

import Control.Concurrent (takeMVar)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (when, unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as M
import Network.Wai.Handler.Warp.HTTP2.Request
import Network.Wai.Handler.Warp.HTTP2.Response
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.IORef
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HPACK

----------------------------------------------------------------

frameReceiver :: Context -> MkReq -> Source -> IO ()
frameReceiver ctx@Context{..} mkreq src =
    E.handle sendGoaway loop `E.finally` takeMVar wait
  where
    sendGoaway (ConnectionError err msg) = do
        csid <- readIORef currentStreamId
        let frame = goawayFrame (toStreamIdentifier csid) err msg
        atomically $ do
            writeTQueue outputQ (OFrame frame)
            writeTQueue outputQ OFinish
    sendGoaway _                         = return ()

    sendReset err sid = do
        let frame = resetFrame err sid
        atomically $ writeTQueue outputQ (OFrame frame)

    loop = do
        hd <- readBytes frameHeaderLength
        if BS.null hd then
            atomically $ writeTQueue outputQ OFinish
          else do
            cont <- guardError $ decodeFrameHeader hd
            when cont loop

    guardError (_, FrameHeader{..})
      | isResponse streamId = E.throwIO $ ConnectionError ProtocolError "stream id should be odd"
    guardError (FrameUnknown _, FrameHeader{..}) = do
        mx <- readIORef continued
        case mx of
            Nothing -> do
                -- ignoring unknown frame
                consume payloadLength
                return True
            Just _  -> E.throwIO $ ConnectionError ProtocolError "stream id should be odd"
    guardError (FramePushPromise, _) =
        E.throwIO $ ConnectionError ProtocolError "push promise is not allowed"
    guardError typhdr@(ftyp, header@FrameHeader{..}) = do
        settings <- readIORef http2settings
        case checkFrameHeader settings typhdr of
            Left h2err -> case h2err of
                StreamError err sid -> do
                    sendReset err sid
                    consume payloadLength
                    return True
                connErr -> E.throwIO connErr
            Right _ -> do
                ex <- E.try $ controlOrStream ftyp header
                case ex of
                    Left (StreamError err sid) -> do
                        sendReset err sid
                        return True
                    Left connErr -> E.throw connErr
                    Right cont -> return cont

    controlOrStream ftyp header@FrameHeader{..}
      | isControl streamId = do
          pl <- readBytes payloadLength
          control ftyp header pl ctx
      | otherwise = do
          checkContinued
          strm@Stream{..} <- getStream
          -- fixme: DataFrame loop
          pl <- readBytes payloadLength
          state <- readIORef streamState
          state' <- stream ftyp header pl ctx state strm
          case state' of
              NoBody hdr -> do
                  resetContinued
                  case validateHeaders hdr of
                      Just vh -> do
                          when (vhCL vh /= Nothing && vhCL vh /= Just 0) $
                              E.throwIO $ StreamError ProtocolError streamId
                          writeIORef streamState HalfClosed
                          let req = mkreq vh (return "")
                          atomically $ writeTQueue inputQ $ Input strm req
                      Nothing -> E.throwIO $ StreamError ProtocolError streamId
              HasBody hdr -> do
                  resetContinued
                  case validateHeaders hdr of
                      Just vh -> do
                          q <- newTQueueIO
                          writeIORef streamState (Body q)
                          writeIORef streamContentLength $ vhCL vh
                          readQ <- newReadBody q
                          bodySource <- mkSource readQ
                          let req = mkreq vh (readSource bodySource)
                          atomically $ writeTQueue inputQ $ Input strm req
                      Nothing -> E.throwIO $ StreamError ProtocolError streamId
              s@(Continued _ _) -> do
                  setContinued
                  writeIORef streamState s
              s -> do -- Body, HalfClosed, Idle, Closed
                  resetContinued
                  writeIORef streamState s
          return True
       where
         setContinued = writeIORef continued (Just streamId)
         resetContinued = writeIORef continued Nothing
         checkContinued = do
             mx <- readIORef continued
             case mx of
                 Nothing  -> return ()
                 Just sid
                   | sid == streamId && ftyp == FrameContinuation -> return ()
                   | otherwise -> E.throwIO $ ConnectionError ProtocolError "continuation frame must follow"
         getStream = do
             let stid = fromStreamIdentifier streamId
             csid <- readIORef currentStreamId
             when (ftyp == FrameHeaders) $
               if stid <= csid then
                   E.throwIO $ ConnectionError ProtocolError "stream identifier must not decrease"
                 else
                   writeIORef currentStreamId stid
             m0 <- readIORef streamTable
             case M.lookup stid m0 of
                 Just strm0 -> return strm0
                 Nothing -> do
                     when (ftyp `notElem` [FrameHeaders,FramePriority]) $
                         E.throwIO $ ConnectionError ProtocolError "this frame is not allowed in an idel stream"
                     cnt <- readIORef concurrency
                     when (cnt >= defaultConcurrency) $
                         E.throwIO $ StreamError RefusedStream streamId
                     ws <- initialWindowSize <$> readIORef http2settings
                     newstrm <- newStream stid (fromIntegral ws)
                     let m1 = M.insert stid newstrm m0
                     writeIORef streamTable m1
                     atomicModifyIORef' concurrency $ \x -> (x+1, ())
                     return newstrm

    consume = void . readBytes

    readBytes len = do
        bs0 <- readSource src
        let len0 = BS.length bs0
        if len0 == 0 then
            return bs0 -- EOF
          else if len0 >= len then do
            let (!frame,!left0) = BS.splitAt len bs0
            leftoverSource src left0
            return frame
          else do
            bs1 <- readSource src
            let len1 = BS.length bs1
            if len0 + len1 >= len then do
                let (!bs1',!left1) = BS.splitAt (len - len0) bs1
                leftoverSource src left1
                return $ BS.append bs0 bs1'
              else
                E.throwIO $ ConnectionError FrameSizeError "not enough frame size"

----------------------------------------------------------------

control :: FrameTypeId -> FrameHeader -> ByteString -> Context -> IO Bool
control FrameSettings header@FrameHeader{..} bs Context{..} = do
    SettingsFrame alist <- guardIt $ decodeSettingsFrame header bs
    case checkSettingsList alist of
        Just x  -> E.throwIO x
        Nothing -> return ()
    unless (testAck flags) $ do
        modifyIORef http2settings $ \old -> updateSettings old alist
        let frame = settingsFrame setAck []
        atomically $ writeTQueue outputQ (OFrame frame)
    return True

control FramePing FrameHeader{..} bs Context{..} =
    if testAck flags then
        E.throwIO $ ConnectionError ProtocolError "the ack flag of this ping frame must not be set"
      else do
        let frame = pingFrame bs
        atomically $ writeTQueue outputQ (OFrame frame)
        return True

control FrameGoAway _ _ Context{..} = do
    atomically $ writeTQueue outputQ OFinish
    return False

control FrameWindowUpdate header@FrameHeader{..} bs Context{..} = do
    WindowUpdateFrame _ <- guardIt $ decodeWindowUpdateFrame header bs
    -- fixme: valid case
    return True

control _ _ _ _ =
    -- must not reach here
    return False

----------------------------------------------------------------

guardIt :: Either HTTP2Error a -> IO a
guardIt x = case x of
    Left err    -> E.throwIO err
    Right frame -> return frame

stream :: FrameTypeId -> FrameHeader -> ByteString -> Context -> StreamState -> Stream -> IO StreamState
stream FrameHeaders header@FrameHeader{..} bs ctx Idle _ = do
    HeadersFrame _ frag <- guardIt $ decodeHeadersFrame header bs
    let endOfStream = testEndStream flags
        endOfHeader = testEndHeader flags
    if endOfHeader then do
        hdr <- decodeHeaderBlock frag ctx
        return $ if endOfStream then NoBody hdr else HasBody hdr
      else
        return $ Continued [frag] endOfStream

stream FrameData header@FrameHeader{..} bs _ s@(Body q) Stream{..} = do
    DataFrame body <- guardIt $ decodeDataFrame header bs
    let endOfStream = testEndStream flags
    len0 <- readIORef streamBodyLength
    let !len = len0 + payloadLength
    writeIORef streamBodyLength len
    atomically $ writeTQueue q body
    if endOfStream then do
        mcl <- readIORef streamContentLength
        case mcl of
            Nothing -> return ()
            Just cl -> when (cl /= len) $ E.throwIO $ StreamError ProtocolError streamId
        atomically $ writeTQueue q ""
        return HalfClosed
      else
        return s

stream FrameContinuation FrameHeader{..} frag ctx (Continued rfrags endOfStream) _ = do
    let endOfHeader = testEndHeader flags
        rfrags' = frag : rfrags
    if endOfHeader then do
        let hdrblk = BS.concat $ reverse rfrags'
        hdr <- decodeHeaderBlock hdrblk ctx
        return $ if endOfStream then NoBody hdr else HasBody hdr
      else
        return $ Continued rfrags' endOfStream

stream FrameContinuation _ _ _ _ _ = E.throwIO $ ConnectionError ProtocolError "continue frame cannot come here"

stream FrameWindowUpdate header@FrameHeader{..} bs Context{..} s Stream{..} = do
    WindowUpdateFrame _ <- guardIt $ decodeWindowUpdateFrame header bs
    -- fixme: valid case
    return s

stream FrameRSTStream header bs _ _ Stream{..} = do
    RSTStreamFrame e <- guardIt $ decoderstStreamFrame header bs
    return $ Closed (Reset e) -- will be written to streamState

    -- this ordering is important
stream _ _ _ _ (Continued _ _) _ = E.throwIO $ ConnectionError ProtocolError "an illegal frame follows header/continuation frames"
stream FrameData FrameHeader{..} _ _ _ _ = E.throwIO $ StreamError StreamClosed streamId
stream _ FrameHeader{..} _ _ _ _ = E.throwIO $ StreamError ProtocolError streamId

----------------------------------------------------------------

decodeHeaderBlock :: HeaderBlockFragment -> Context -> IO HeaderList
decodeHeaderBlock hdrblk Context{..} = do
    hdrtbl <- readIORef decodeDynamicTable
    (hdrtbl', hdr) <- decodeHeader hdrtbl hdrblk `E.onException` cleanup
    writeIORef decodeDynamicTable hdrtbl'
    return hdr
  where
    cleanup = E.throwIO $ ConnectionError CompressionError "cannot decompress the header"
