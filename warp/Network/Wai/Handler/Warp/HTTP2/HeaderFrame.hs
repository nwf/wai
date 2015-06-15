{-# LANGUAGE RecordWildCards, OverloadedStrings #-}

module Network.Wai.Handler.Warp.HTTP2.HeaderFrame where

import Control.Arrow (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import Data.CaseInsensitive (foldedCase)
import Data.IORef (readIORef, writeIORef)
import Network.HPACK
import qualified Network.HTTP.Types as H
import Network.HTTP2
import Network.Wai
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.Header
import Network.Wai.Handler.Warp.Response
import qualified Network.Wai.Handler.Warp.Settings as S
import Network.Wai.Handler.Warp.Types

headerFrame :: Context -> InternalInfo -> S.Settings -> Int -> Response
            -> IO ByteString
headerFrame Context{..} ii settings stid rsp = do
    hdr1 <- addServerAndDate hdr0
    let hdr2 = (":status", status) : map (first foldedCase) hdr1
    ehdrtbl <- readIORef encodeDynamicTable
    (ehdrtbl',hdrfrg) <- encodeHeader defaultEncodeStrategy ehdrtbl hdr2
    writeIORef encodeDynamicTable ehdrtbl'
    return $ encodeFrame einfo $ HeadersFrame Nothing hdrfrg
  where
    hdr0 = responseHeaders rsp
    status = B8.pack $ show $ H.statusCode $ responseStatus rsp
    dc = dateCacher ii
    rspidxhdr = indexResponseHeader hdr0
    defServer = S.settingsServerName settings
    addServerAndDate = addDate dc rspidxhdr . addServer defServer rspidxhdr
    einfo = encodeInfo setEndHeader stid

