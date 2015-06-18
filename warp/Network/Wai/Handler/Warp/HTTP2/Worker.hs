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

-- fixme: sending a reset frame?
worker :: Context -> T.Manager -> Application -> Responder -> IO ()
worker Context{..} tm app responder = do
    tid <- myThreadId
    ref <- newIORef Nothing
    bracket (T.register tm (E.throwTo tid Break)) T.cancel $ \th ->
        go th ref `E.catch` gonext th ref
  where
    go th ref = forever $ do
        Input strm req <- atomically $ readTQueue inputQ
        T.tickle th
        writeIORef ref (Just strm)
        -- fixme: what about IO errors?
        void $ app req $ responder strm
    gonext th ref Break = doit `E.catch` gonext th ref
      where
        doit = do
            m <- readIORef ref
            case m of
                Nothing   -> return ()
                Just strm -> do
                    writeIORef (streamState strm) $ Closed Killed
                    writeIORef ref Nothing
                    go th ref

