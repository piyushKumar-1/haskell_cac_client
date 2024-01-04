{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}



module Main where

import Foreign
import Foreign.C

import Foreign.ForeignPtr.Unsafe  (unsafeForeignPtrToPtr)
import Control.Concurrent
import Prelude
import Data.Text 
import GHC.Generics
import Data.Aeson
import Data.HashMap.Strict as HashMap
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Text.Encoding
import Data.Maybe


foreign import ccall "init_cac_clients" init_cac_clients :: CString -> CULong -> Ptr CString -> CInt -> IO (Ptr CULong)
foreign import ccall "eval_ctx" eval_ctx :: CString -> CString -> IO (Ptr CChar)
foreign import ccall "&free_json_data" free_json_data :: FunPtr (Ptr CChar -> IO ())
foreign import ccall "init_superposition_clients" init_superposition_clients :: CString -> CULong -> Ptr CString -> CInt -> IO (Ptr CULong)
foreign import ccall "eval_experiment" eval_experiment ::  CString -> CString -> CInt -> IO (Ptr CChar)
foreign import ccall "run_polling_updates" run_polling_updates :: IO ()
foreign import ccall "start_polling_updates" start_polling_updates :: IO ()


initCacClients :: CString -> CULong -> Ptr CString -> CInt -> IO (ForeignPtr CULong)
initCacClients hostname polling_interval_secs  tenants tenants_count = do
  resPtr <- init_cac_clients hostname polling_interval_secs  tenants tenants_count
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
  putStrLn "freeing json data"
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
defaultHashMap = HashMap.fromList[(pack "defualt", pack "default")]

cStringToText :: CString -> IO Text
cStringToText cStr = pack <$> peekCString cStr

-- Parse Text to HashMap
parseJsonToHashMap :: Text -> Maybe MyHashMap
parseJsonToHashMap txt = decode . BS.fromStrict . encodeUtf8 $ txt




main :: IO ()
main = do
  putStrLn "Hello, Haskell!"
  arr1 <- mapM stringToCString ["mjos"]
  arr2 <- newArray arr1
  host <- stringToCString "http://localhost:8080"
  _ <- initCacClients host 10  arr2 (1 ::CInt)
  _ <- initSuperPositionClients host 1 arr2 (1 ::CInt)
  _ <- forkIO run_polling_updates
  -- _ <- forkIO start_polling_updates
  tenant <- stringToCString "mjos"

  -- let myHashMap = HashMap.fromList[(pack "distance", pack "10")]
  -- val <- hashMapToCString myHashMap
  -- result <- evalCtx tenant val >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  -- let final = fromMaybe defaultHashMap $ parseJsonToHashMap result  
  -- putStrLn $ show final
  -- context <- stringToCString "{\"Os\":\"Linux\"}"
  -- _ <- evalCtx tenant context >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn 
  context1 <- stringToCString "{\"merchantId\":\"random\"}"
  _ <- evalExperiment tenant context1 23 >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  putStrLn "evaluated context"
