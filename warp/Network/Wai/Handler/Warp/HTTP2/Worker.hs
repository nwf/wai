{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2.Worker where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception as E
import Control.Monad (void, forever)
import Data.Typeable
import Network.Wai
import Network.Wai.Handler.Warp.HTTP2.Response
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.IORef
import qualified Network.Wai.Handler.Warp.Timeout as T

data Break = Break deriving (Show, Typeable)

instance Exception Break

-- fixme: tickle activity
-- fixme: sending a reset frame?
worker :: Context -> T.Manager -> Application -> Responder -> IO ()
worker Context{..} tm app responder = do
    tid <- myThreadId
    bracket (T.register tm (E.throwTo tid Break)) T.cancel $ \th ->
        go th `E.catch` gonext th
  where
    go th = forever $ do
        Input strm@Stream{..} req <- atomically $ readTQueue inputQ
        T.tickle th
        void $ app req $ responder strm
        -- fixme: how to remove Closed streams from streamTable?
        writeIORef streamState Closed
    gonext th Break = go th `E.catch` gonext th

