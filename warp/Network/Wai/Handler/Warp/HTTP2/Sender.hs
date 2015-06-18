{-# LANGUAGE RecordWildCards, OverloadedStrings, BangPatterns, ForeignFunctionInterface #-}

module Network.Wai.Handler.Warp.HTTP2.Sender (frameSender) where

import Control.Concurrent (putMVar)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (void)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder.Extra as B
import Data.IORef (writeIORef)
import Foreign.C.Types
import Foreign.Ptr
import Network.HTTP2
import Network.Wai
import Network.Wai.Handler.Warp.Buffer
import Network.Wai.Handler.Warp.FdCache
import Network.Wai.Handler.Warp.HTTP2.HeaderFrame
import Network.Wai.Handler.Warp.HTTP2.Response
import Network.Wai.Handler.Warp.HTTP2.Types
import qualified Network.Wai.Handler.Warp.Settings as S
import Network.Wai.Handler.Warp.Types
import Network.Wai.Internal (Response(..))
import System.Posix.Types

----------------------------------------------------------------

frameSender :: Context -> Connection -> InternalInfo -> S.Settings -> IO ()
frameSender ctx@Context{..} conn@Connection{..} ii settings = do
    connSendAll initialFrame
    loop `E.finally` putMVar wait ()
  where
    initialSettings = [(SettingsMaxConcurrentStreams,defaultConcurrency)]
    initialFrame = settingsFrame id initialSettings
    loop = atomically (readTQueue outputQ) >>= switch
    switch OFinish        = return ()
    switch (OFrame frame) = do
        connSendAll frame
        loop
    switch (OResponse strm rsp) = do
        -- Header frame
        let sid = streamNumber strm
        hdrframe <- headerFrame ctx ii settings sid rsp
        -- fixme: length check + Continue
        void $ copy connWriteBuffer hdrframe
        -- Data frame
        let otherLen = BS.length hdrframe
            datPayloadOff = otherLen + frameHeaderLength
        Next datPayloadLen mnext <- responseToNext conn ii datPayloadOff rsp
        fillSend strm otherLen datPayloadLen mnext
    switch (ONext strm curr) = do
        -- Data frame
        Next datPayloadLen mnext <- curr
        fillSend strm 0 datPayloadLen mnext
    fillSend strm otherLen datPayloadLen mnext = do
        -- fixme: length check
        let sid = streamNumber strm
            dathdr = dataFrameHeadr datPayloadLen sid mnext
        void $ copy (connWriteBuffer `plusPtr` otherLen) dathdr
        let total = otherLen + frameHeaderLength  + datPayloadLen
        bs <- toBS connWriteBuffer total
        connSendAll bs
        case mnext of
            Nothing   -> do
                writeIORef (streamState strm) Closed
                loop
            Just next -> do
                atomically $ writeTQueue outputQ (ONext strm next)
                loop
    dataFrameHeadr len sid mnext = encodeFrameHeader FrameData hinfo
      where
        hinfo = FrameHeader len flag (toStreamIdentifier sid)
        flag = case mnext of
            Nothing -> setEndStream defaultFlags
            Just _  -> defaultFlags

----------------------------------------------------------------

{-
ResponseFile Status ResponseHeaders FilePath (Maybe FilePart)
ResponseBuilder Status ResponseHeaders Builder
ResponseStream Status ResponseHeaders StreamingBody
ResponseRaw (IO ByteString -> (ByteString -> IO ()) -> IO ()) Response
-}

responseToNext :: Connection -> InternalInfo -> Int -> Response -> IO Next
responseToNext Connection{..} _ off (ResponseBuilder _ _ bb) = do
    let datBuf = connWriteBuffer `plusPtr` off
        room = connBufferSize - off
    (len, signal) <- B.runBuilder bb datBuf room
    nextForBuilder len connWriteBuffer connBufferSize signal

responseToNext Connection{..} ii off (ResponseFile _ _ path mpart) = do
    -- fixme: no fdcache
    let Just fdcache = fdCacher ii
    (fd, refresh) <- getFd fdcache path
    let datBuf = connWriteBuffer `plusPtr` off
        Just part = mpart -- fixme: Nothing
        room = connBufferSize - off
        start = filePartOffset part
        bytes = filePartByteCount part
    len <- positionRead fd datBuf (mini room bytes) start
    refresh
    let len' = fromIntegral len
    nextForFile len connWriteBuffer connBufferSize fd (start + len') (bytes - len') refresh

responseToNext _ _ _ _ = error "responseToNext"

----------------------------------------------------------------

fillBufBuilder :: Buffer -> BufSize -> B.BufferWriter -> IO Next
fillBufBuilder buf siz writer = do
    let payloadBuf = buf `plusPtr` frameHeaderLength
        room = siz - frameHeaderLength
    (len, signal) <- writer payloadBuf room
    nextForBuilder len buf siz signal

nextForBuilder :: Int -> Buffer -> BufSize -> B.Next -> IO Next
nextForBuilder len _   _   B.Done = return $ Next len Nothing
nextForBuilder len buf siz (B.More minSize writer)
  | siz < minSize = error "toBufIOWith: fillBufBuilder: minSize"
  | otherwise     = return $ Next len (Just (fillBufBuilder buf siz writer))
nextForBuilder len buf siz (B.Chunk bs writer)
  | bs == ""      = return $ Next len (Just (fillBufBuilder buf siz writer))
  | otherwise     = error "toBufIOWith: fillBufBuilder: bs"

----------------------------------------------------------------

fillBufFile :: Buffer -> BufSize -> Fd -> Integer -> Integer -> IO () -> IO Next
fillBufFile buf siz fd start bytes refresh = do
    let payloadBuf = buf `plusPtr` frameHeaderLength
        room = siz - frameHeaderLength
    len <- positionRead fd payloadBuf (mini room bytes) start
    let len' = fromIntegral len
    refresh
    nextForFile len buf siz fd (start + len') (bytes - len') refresh

nextForFile :: Int -> Buffer -> BufSize -> Fd -> Integer -> Integer -> IO () -> IO Next
nextForFile 0   _   _   _  _     _     _       = return $ Next 0 Nothing
nextForFile len _   _   _  _     0     _       = return $ Next len Nothing
nextForFile len buf siz fd start bytes refresh =
    return $ Next len (Just (fillBufFile buf siz fd start bytes refresh))

mini :: Int -> Integer -> Int
mini i n
  | fromIntegral i < n = i
  | otherwise          = fromIntegral n

-- fixme: Windows
positionRead :: Fd -> Buffer -> BufSize -> Integer -> IO Int
positionRead (Fd fd) buf siz off =
    fromIntegral <$> c_pread fd (castPtr buf) (fromIntegral siz) (fromIntegral off)

foreign import ccall unsafe "pread"
  c_pread :: CInt -> Ptr CChar -> ByteCount -> FileOffset -> IO ByteCount -- fixme
