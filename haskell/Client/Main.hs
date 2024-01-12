{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE StandaloneDeriving #-}

module Client.Main where

import Control.Concurrent
import Data.Aeson as DA
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.HashMap.Strict as HashMap
import Data.Maybe
import Data.Text as Text
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LTE
import Data.Text.Encoding
import Foreign
import Foreign.C
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
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

evalCtx :: String -> String -> IO (Maybe MyHashMap)
evalCtx tenant context = do
  putStrLn $ "evalCtx called with tenant: " <> tenant <> " and context: " <> context
  tenant' <- stringToCString tenant
  context' <- stringToCString context
  resPtr <- eval_ctx tenant' context'
  resPtr' <- freeJsonData resPtr
  withForeignPtr resPtr' peekCString >>= putStrLn
  result <- withForeignPtr resPtr' cStringToText
  pure $ parseJsonToHashMap result

evalExperiment :: String -> String -> Int -> IO (Maybe MyHashMap)
evalExperiment tenant context toss = do
  tenant' <- stringToCString tenant
  context' <- stringToCString context
  resPtr <- eval_experiment tenant' context' $ fromIntegral toss
  resPtr' <- freeJsonData resPtr
  result <- withForeignPtr resPtr' cStringToText
  pure $ parseJsonToHashMap result

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

hashMapToString :: MyHashMap -> IO (String)
hashMapToString hashMap = pure $ Text.unpack . LT.toStrict . LTE.decodeUtf8 . encode $ hashMap

-- stringToCString (unpack json)

type MyHashMap = HashMap Text DA.Value

defaultHashMap :: MyHashMap
defaultHashMap = HashMap.fromList [(pack "defualt", (DA.String (Text.pack "default")))]

cStringToText :: CString -> IO Text
cStringToText cStr = pack <$> peekCString cStr

-- Parse Text to HashMap
parseJsonToHashMap :: Text -> Maybe MyHashMap
parseJsonToHashMap txt = DA.decode . BS.fromStrict . encodeUtf8 $ txt

main :: IO ()
main = do
  putStrLn "Starting Haskell client..."
  arr1 <- mapM stringToCString ["test", "dev"]
  arr2 <- newArray arr1
  host <- stringToCString "http://localhost:8080"
  _ <- initCacClients host 10 arr2 (fromIntegral (P.length arr1))
  _ <- initSuperPositionClients host 1 arr2 (fromIntegral (P.length arr1))
  _ <- mapM (\tenant -> forkOS (run_polling_updates tenant)) arr1
  _ <- mapM (\tenant -> forkOS (start_polling_updates tenant)) arr1
  tenant1 <- stringToCString "test"
  -- tenant2 <- stringToCString "dev"
  farePolicyCond <- hashMapToString $ HashMap.fromList [(pack "merchantOperatingCityId", DA.String (Text.pack ("NAMMA_YATRI"))), (pack "tripDistance", DA.String (Text.pack ("500")))]
  contextValue <- evalCtx "test" farePolicyCond
  putStrLn $ "contextValue: " <> show contextValue
  value <- (hashMapToString (fromMaybe (HashMap.fromList [(pack "defaultKey", DA.String (Text.pack ("defaultValue")))]) contextValue))
  putStrLn $ "contextValueEvaluated: " <> show value
  -- result1 <- evalCtx tenant1 context >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  -- result2 <- evalCtx tenant2 context >>= \evalCtx' -> withForeignPtr evalCtx' cStringToText
  -- let final1 = fromMaybe defaultHashMap $ parseJsonToHashMap result1
  -- let final2 = fromMaybe defaultHashMap $ parseJsonToHashMap result2
  -- putStrLn $ ("final1 is " <> show final1 <> " final2 is " <> show final2)
  -- _ <- evalCtx tenant context >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  -- context1 <- stringToCString "{\"merchantId\":\"random\"}"
  -- _ <- evalExperiment tenant context1 23 >>= \evalCtx' -> withForeignPtr evalCtx' peekCString >>= putStrLn
  putStrLn "created the clients and started polling updates..."
