{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE StandaloneDeriving #-}

module Main where

import Control.Concurrent
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.HashMap.Strict as HashMap
import Data.Maybe
import Data.Text
import Data.Text.Encoding
import Foreign
import Foreign.C
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import GHC.Generics
import Prelude as P

-- import Database.LevelDB.Internal

foreign import ccall "init_cac_clients" init_cac_clients :: CString -> CULong -> Ptr CString -> CInt -> IO (Ptr CULong)

foreign import ccall "eval_ctx" eval_ctx :: CString -> CString -> IO (Ptr CChar)

foreign import ccall "&free_json_data" free_json_data :: FunPtr (Ptr CChar -> IO ())

foreign import ccall "init_superposition_clients" init_superposition_clients :: CString -> CULong -> Ptr CString -> CInt -> IO (Ptr CULong)

foreign import ccall "eval_experiment" eval_experiment :: CString -> CString -> CInt -> IO (Ptr CChar)

foreign import ccall "run_polling_updates" run_polling_updates :: CString -> IO ()

foreign import ccall "start_polling_updates" start_polling_updates :: CString -> IO ()

initCacClients :: CString -> CULong -> Ptr CString -> CInt -> IO (ForeignPtr CULong)
initCacClients hostname polling_interval_secs tenants tenants_count = do
  resPtr <- init_cac_clients hostname polling_interval_secs tenants tenants_count
  newForeignPtr_ resPtr

initSuperPositionClients :: CString -> CULong -> Ptr CString -> CInt -> IO (ForeignPtr CULong)
initSuperPositionClients hostname polling_interval tenants tenants_count = do
  resPtr <- init_superposition_clients hostname polling_interval tenants tenants_count
  newForeignPtr_ resPtr

evalCtx :: CString -> CString -> IO (ForeignPtr CChar)
evalCtx tenant context = do
  resPtr <- eval_ctx tenant context
  freeJsonData resPtr

evalExperiment :: CString -> CString -> CInt -> IO (ForeignPtr CChar)
evalExperiment tenant context toss = do
  resPtr <- eval_experiment tenant context toss
  freeJsonData resPtr

freeJsonData :: Ptr CChar -> IO (ForeignPtr CChar)
freeJsonData ptr = do
  newForeignPtr free_json_data ptr

stringToCString :: String -> IO CString
stringToCString str = newCString str

printForeignPtr :: ForeignPtr CULong -> IO ()
printForeignPtr fptr = do
  let ptr = unsafeForeignPtrToPtr fptr
  culongValue <- peek ptr
  putStrLn $ "CULong value: " ++ show culongValue

data GeoRestriction
  = Unrestricted
  | Regions [Text]
  deriving (Show, Generic, FromJSON, ToJSON, Read, Eq, Ord)

data GeofencingConfig = GeofencingConfig
  { origin :: GeoRestriction,
    destination :: GeoRestriction
  }
  deriving (Show, Generic, FromJSON, ToJSON, Read)

hashMapToCString :: HashMap Text Text -> IO (CString)
hashMapToCString hashMap = do
  newCString . BS.unpack . encode $ hashMap

-- stringToCString (unpack json)

type MyHashMap = HashMap Text Text

defaultHashMap :: MyHashMap
defaultHashMap = HashMap.fromList [(pack "defualt", pack "default")]

cStringToText :: CString -> IO Text
cStringToText cStr = pack <$> peekCString cStr

-- Parse Text to HashMap
parseJsonToHashMap :: Text -> Maybe MyHashMap
parseJsonToHashMap txt = decode . BS.fromStrict . encodeUtf8 $ txt

main :: IO ()
main = do
  putStrLn "Starting Haskell client..."
  !arr1 <- mapM stringToCString ["test", "dev"]
  arr2 <- newArray arr1
  host <- stringToCString "http://localhost:8080"
  _ <- initCacClients host 10 arr2 (fromIntegral (P.length arr1))
  _ <- initSuperPositionClients host 1 arr2 (fromIntegral (P.length arr1))
  _ <- mapM (\tenant -> forkOS (run_polling_updates tenant)) arr1
  _ <- mapM (\tenant -> forkOS (start_polling_updates tenant)) arr1
  tenant1 <- stringToCString "test"
  tenant2 <- stringToCString "dev"
  -- let myHashMap = HashMap.fromList[(pack "distance", pack "10")]
  -- val <- hashMapToCString myHashMap
  context <- stringToCString "{\"Os\":\"7200\"}"
  result1 <- evalCtx tenant1 context >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  result2 <- evalCtx tenant2 context >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  let final1 = fromMaybe defaultHashMap $ parseJsonToHashMap result1
  let final2 = fromMaybe defaultHashMap $ parseJsonToHashMap result2
  putStrLn $ ("final1 is " <> show final1 <> " final2 is " <> show final2)
  -- _ <- evalCtx tenant context >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  -- context1 <- stringToCString "{\"merchantId\":\"random\"}"
  -- _ <- evalExperiment tenant context1 23 >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  putStrLn "evaluated context"
