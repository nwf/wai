{-# LANGUAGE OverloadedStrings, CPP #-}

module Network.Wai.Handler.Warp.HTTP2.Types where

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>),(<*>))
#endif
import Control.Concurrent
import Control.Concurrent.STM
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M
import qualified Network.HTTP.Types as H
import Network.Wai (Request, Response)
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HPACK

----------------------------------------------------------------

http2ver :: H.HttpVersion
http2ver = H.HttpVersion 2 0

isHTTP2 :: Transport -> Bool
isHTTP2 TCP = False
isHTTP2 tls = useHTTP2
  where
    useHTTP2 = case tlsNegotiatedProtocol tls of
        Nothing    -> False
        Just proto -> "h2-" `BS.isPrefixOf` proto

----------------------------------------------------------------

data Next = Next Int (Maybe (IO Next))

data Input = Input Stream Request
data Output = OFinish
            | OResponse Stream Response
            | OFrame ByteString
            | ONext Stream (IO Next)

type StreamTable = IntMap Stream

data Context = Context {
    http2settings      :: IORef Settings
  , streamTable        :: IORef StreamTable
  , concurrency        :: IORef Int
  , continued          :: IORef (Maybe StreamIdentifier)
  , currentStreamId    :: IORef Int
  , inputQ             :: TQueue Input
  , outputQ            :: TQueue Output
  , encodeDynamicTable :: IORef DynamicTable
  , decodeDynamicTable :: IORef DynamicTable
  , wait               :: MVar ()
  , connectionWindow   :: IORef WindowSize
  }

----------------------------------------------------------------

newContext :: IO Context
newContext = Context <$> newIORef defaultSettings
                     <*> newIORef M.empty
                     <*> newIORef 0
                     <*> newIORef Nothing
                     <*> newIORef 0
                     <*> newTQueueIO
                     <*> newTQueueIO
                     <*> (newDynamicTableForEncoding 4096 >>= newIORef)
                     <*> (newDynamicTableForDecoding 4096 >>= newIORef)
                     <*> newEmptyMVar
                     <*> newIORef (fromIntegral defaultInitialWindowSize)

----------------------------------------------------------------

data ClosedCode = Finished | Killed | Reset ErrorCodeId deriving Show

data StreamState =
    Idle
  | Continued [HeaderBlockFragment] Bool
  | NoBody HeaderList
  | HasBody HeaderList
  | Body (TQueue ByteString)
  | HalfClosed
  | Closed ClosedCode

instance Show StreamState where
    show Idle            = "Idle"
    show (Continued _ _) = "Continued"
    show (NoBody  _)     = "NoBody"
    show (HasBody _)     = "HasBody"
    show (Body _)        = "Body"
    show HalfClosed      = "HalfClosed"
    show (Closed e)      = "Closed: " ++ show e

----------------------------------------------------------------

data Stream = Stream {
    streamNumber        :: Int
  , streamState         :: IORef StreamState
  -- Next two fields are for error checking.
  , streamContentLength :: IORef (Maybe Int)
  , streamBodyLength    :: IORef Int
  , streamWindow        :: IORef WindowSize
  }

newStream :: Int -> WindowSize -> IO Stream
newStream sid win = Stream sid <$> newIORef Idle
                               <*> newIORef Nothing
                               <*> newIORef 0
                               <*> newIORef win

----------------------------------------------------------------

defaultConcurrency :: Int
defaultConcurrency = 100
