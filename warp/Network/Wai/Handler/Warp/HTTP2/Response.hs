{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2.Response where

import Control.Concurrent.STM
import Data.ByteString (ByteString)
import Network.HTTP2
import Network.Wai
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Internal (ResponseReceived(..))

----------------------------------------------------------------

type Responder = Stream -> Response -> IO ResponseReceived

----------------------------------------------------------------

goawayFrame :: StreamIdentifier -> ErrorCodeId -> ByteString -> ByteString
goawayFrame sid etype debugmsg = encodeFrame einfo frame
  where
    einfo = encodeInfo id 0
    frame = GoAwayFrame sid etype debugmsg

resetFrame :: ErrorCodeId -> StreamIdentifier -> ByteString
resetFrame etype sid = encodeFrame einfo frame
  where
    einfo = encodeInfo id $ fromStreamIdentifier sid
    frame = RSTStreamFrame etype

settingsFrame :: (FrameFlags -> FrameFlags) -> SettingsList -> ByteString
settingsFrame func alist = encodeFrame einfo $ SettingsFrame alist
  where
    einfo = encodeInfo func 0

pingFrame :: ByteString -> ByteString
pingFrame bs = encodeFrame einfo $ PingFrame bs
  where
    einfo = encodeInfo setAck 0

----------------------------------------------------------------

output :: Context -> Stream -> Response -> IO ResponseReceived
output Context{..} strm rsp = do
    atomically $ writeTQueue outputQ (OResponse strm rsp)
    return ResponseReceived
