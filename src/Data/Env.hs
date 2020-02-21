{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Data.Env where

import Control.Monad.Except
import Control.Monad.State
import Path
import System.Info

import Data.Basic
import Data.Code
import Data.Constraint
import Data.LLVM
import Data.Term
import Data.Tree
import Data.WeakTerm

import qualified Data.HashMap.Strict as Map
import qualified Data.IntMap.Strict as IntMap
import qualified Data.PQueue.Min as Q
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import qualified Text.Show.Pretty as Pr

type ConstraintQueue = Q.MinQueue EnrichedConstraint

type IncludeGraph = Map.HashMap (Path Abs File) [Path Abs File]

type FileInfo = [(Meta, Identifier, WeakTermPlus)]

type FileEnv = Map.HashMap (Path Abs File) FileInfo

type Justification = Loc

type RuleEnv = Map.HashMap Int (Maybe [Data.WeakTerm.IdentifierPlus])

type UnivInstEnv = IntMap.IntMap (S.Set Int)

data Env =
  Env
    { count :: Int
    , phase :: Int
    , target :: Maybe Target
    , mainFilePath :: Path Abs File
    , currentFilePath :: Path Abs File
    , includeGraph :: IncludeGraph -- to detect cyclic `include`
    , keywordEnv :: S.Set T.Text -- list of reserved keywords
    , notationEnv :: [(TreePlus, TreePlus)] -- macro transformers
    , constantEnv :: Map.HashMap T.Text Int
    , fileEnv :: FileEnv -- path ~> identifiers defined in the file at toplevel
    , enumEnv :: Map.HashMap T.Text [(T.Text, Int)] -- [("choice", [("left", 0), ("right", 1)]), ...]
    , revEnumEnv :: Map.HashMap T.Text (T.Text, Int) -- [("left", ("choice", 0)), ("right", ("choice", 1)), ...]
    , nameEnv :: IntMap.IntMap Int -- [("foo", "foo.13"), ...] (as corresponding int)
    , revNameEnv :: IntMap.IntMap Int -- [("foo.13", "foo"), ...] (as corresponding int)
    -- , nameEnv :: Map.HashMap Identifier Identifier -- [("foo", "foo.13"), ...]
    -- , revNameEnv :: Map.HashMap Identifier Identifier -- [("foo.13", "foo"), ...]
    , formationEnv :: IntMap.IntMap (Maybe WeakTermPlus)
    , inductiveEnv :: RuleEnv -- "list" ~> (cons, Pi (A : tau). A -> list A -> list A)
    , coinductiveEnv :: RuleEnv -- "tail" ~> (head, Pi (A : tau). stream A -> A)
    , weakTypeEnv :: IntMap.IntMap (WeakTermPlus, UnivLevelPlus) -- var ~> (typeof(var), level-of-type)
    , equalityEnv :: [(UnivLevel, UnivLevel)]
    , univInstEnv :: UnivInstEnv
    , univRenameEnv :: IntMap.IntMap Int
    , quasiConstEnv :: S.Set Identifier
    , typeEnv :: IntMap.IntMap (TermPlus, UnivLevelPlus)
    -- , typeEnv :: Map.HashMap Identifier (TermPlus, UnivLevelPlus)
    , constraintEnv :: [PreConstraint] -- for type inference
    , constraintQueue :: ConstraintQueue
    , levelEnv :: [LevelConstraint]
    , substEnv :: IntMap.IntMap WeakTermPlus -- metavar ~> beta-equivalent weakterm
    , zetaEnv :: IntMap.IntMap (WeakTermPlus, WeakTermPlus, UnivLevelPlus)
    , chainEnv :: IntMap.IntMap [(Meta, Identifier, TermPlus)] -- var/const ~> the closed var chain of its type
    , codeEnv :: Map.HashMap Identifier ([Identifier], CodePlus) -- f ~> thunk (lam (x1 ... xn) e)
    , llvmEnv :: Map.HashMap Identifier ([Identifier], LLVM)
    , shouldColorize :: Bool
    }

initialEnv :: Path Abs File -> Bool -> Env
initialEnv path colorizeFlag =
  Env
    { count = 0
    , phase = 0
    , target = Nothing
    , includeGraph = Map.empty
    , notationEnv = []
    , keywordEnv = S.empty
    , constantEnv = Map.empty
    , enumEnv = Map.empty
    , fileEnv = Map.empty
    , revEnumEnv = Map.empty
    , nameEnv = IntMap.empty
    , revNameEnv = IntMap.empty
    , formationEnv = IntMap.empty
    , inductiveEnv = Map.empty
    , coinductiveEnv = Map.empty
    , equalityEnv = []
    , univInstEnv = IntMap.empty
    , univRenameEnv = IntMap.empty
    , quasiConstEnv = S.empty
    , weakTypeEnv = IntMap.empty
    , typeEnv = IntMap.empty
    , chainEnv = IntMap.empty
    , codeEnv = Map.empty
    , llvmEnv = Map.empty
    , constraintEnv = []
    , constraintQueue = Q.empty
    , levelEnv = []
    , substEnv = IntMap.empty
    , zetaEnv = IntMap.empty
    , mainFilePath = path
    , currentFilePath = path
    , shouldColorize = colorizeFlag
    }

-- type WithEnv a = StateT Env (ExceptT Identifier IO) a
type WithEnv a = StateT Env (ExceptT [IO ()] IO) a

evalWithEnv :: (Show a) => WithEnv a -> Env -> IO (Either [IO ()] a)
evalWithEnv c env = do
  resultOrErr <- runExceptT (runStateT c env)
  case resultOrErr of
    Left err -> return $ Left err
    Right (result, _) -> return $ Right result

throwError' :: T.Text -> WithEnv a
throwError' x = throwError [TIO.putStrLn x]

-- fixme: return error if i + 1 == 0 (overflow)
newCount :: WithEnv Int
newCount = do
  i <- gets count
  modify (\e -> e {count = i + 1})
  return i

newUnivLevel :: WithEnv UnivLevel
newUnivLevel = newCount

newName :: WithEnv Identifier
newName = do
  i <- newCount
  return $ I ("-", i)

newNameWith :: Identifier -> WithEnv Identifier
newNameWith (I (s, i)) = do
  j <- newCount
  modify (\e -> e {nameEnv = IntMap.insert i j (nameEnv e)})
  return $ I (s, j)

newNameWith' :: T.Text -> WithEnv Identifier
newNameWith' s = do
  i <- newCount
  return $ I (s, i)

newNameWith'' :: T.Text -> WithEnv Identifier
newNameWith'' s = do
  i <- newCount
  return $ I (s <> "-" <> T.pack (show i), i)

newLLVMNameWith :: Identifier -> WithEnv Identifier
newLLVMNameWith (I (s, i)) = do
  j <- newCount
  modify (\e -> e {nameEnv = IntMap.insert i j (nameEnv e)})
  modify (\e -> e {revNameEnv = IntMap.insert j i (revNameEnv e)})
  return $ I (llvmString s, j)

newLLVMNameWith' :: T.Text -> WithEnv Identifier
newLLVMNameWith' s = do
  i <- newCount
  return $ I (llvmString s <> "-" <> T.pack (show i), i)

llvmString :: T.Text -> T.Text
llvmString "" = error "llvmString called for the empty string"
llvmString s = T.cons (llvmHeadChar $ T.head s) (T.map llvmTailChar $ T.tail s)

llvmHeadCharSet :: S.Set Char
llvmHeadCharSet =
  S.fromList $
  "-$._" <> "abcdefghijklmnopqrstuvwxyz" <> "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

llvmHeadChar :: Char -> Char
llvmHeadChar x =
  if x `S.member` llvmHeadCharSet
    then x
    else '-'

llvmTailCharSet :: S.Set Char
llvmTailCharSet =
  S.fromList $
  "-$._" <>
  "abcdefghijklmnopqrstuvwxyz" <> "ABCDEFGHIJKLMNOPQRSTUVWXYZ" <> "0123456789"

-- foo = S.fromList $ "-$._" <> "abcdefghijklmnopqrstuvwxyz" <> "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
llvmTailChar :: Char -> Char
llvmTailChar x =
  if x `S.member` llvmTailCharSet
    then x
    else '-'

lookupTypeEnv' :: Identifier -> WithEnv TermPlus
lookupTypeEnv' (I (s, i))
  | Just _ <- asLowTypeMaybe s = do
    l <- newUnivLevel
    return (emptyMeta, TermTau l)
  | otherwise = do
    mt <- gets (IntMap.lookup i . typeEnv)
    case mt of
      Just (t, _) -> return t
      Nothing ->
        throwError
          [TIO.putStrLn $ s <> " is not found in the type environment."]

lookupNameEnv :: Identifier -> WithEnv Identifier
lookupNameEnv (I (s, i)) = do
  env <- get
  case IntMap.lookup i (nameEnv env) of
    Just i' -> return $ I (s, i')
    Nothing -> throwError [TIO.putStrLn $ "undefined variable: " <> s]

isDefinedEnum :: T.Text -> WithEnv Bool
isDefinedEnum name = do
  env <- get
  let labelList = join $ Map.elems $ enumEnv env
  return $ name `elem` map fst labelList

getTarget :: WithEnv Target
getTarget = do
  mtarget <- gets target
  case mtarget of
    Just t -> return t
    Nothing -> do
      currentOS <- getOS
      currentArch <- getArch
      return (currentOS, currentArch)

getOS :: WithEnv OS
getOS = do
  case os of
    "linux" -> return OSLinux
    "darwin" -> return OSDarwin
    s -> throwError [putStrLn $ "unsupported target os: " <> show s]

getArch :: WithEnv Arch
getArch = do
  case arch of
    "x86_64" -> return Arch64
    s ->
      throwError [TIO.putStrLn $ "unsupported target arch: " <> T.pack (show s)]

-- for debug
p :: String -> WithEnv ()
p s = liftIO $ putStrLn s

p' :: (Show a) => a -> WithEnv ()
p' s = liftIO $ putStrLn $ Pr.ppShow s

toStr :: (Show a) => a -> String
toStr s = Pr.ppShow s

toInfo :: (Show a) => String -> a -> String
toInfo s x = "assertion failure:\n" ++ s ++ "\n" ++ toStr x

newDataUpsilonWith :: T.Text -> WithEnv (Identifier, DataPlus)
newDataUpsilonWith name = newDataUpsilonWith' name emptyMeta

newDataUpsilonWith' :: T.Text -> Meta -> WithEnv (Identifier, DataPlus)
newDataUpsilonWith' name m = do
  x <- newNameWith' name
  return (x, (m, DataUpsilon x))

enumValueToInteger :: EnumValue -> WithEnv Integer
enumValueToInteger labelOrNat =
  case labelOrNat of
    EnumValueLabel l -> toInteger <$> getEnumNum l
    EnumValueIntS _ i -> return i
    EnumValueIntU _ i -> return i
    EnumValueNat _ j -> return $ toInteger j

getEnumNum :: T.Text -> WithEnv Int
getEnumNum label = do
  renv <- gets revEnumEnv
  case Map.lookup label renv of
    Nothing -> throwError [TIO.putStrLn $ "no such enum is defined: " <> label]
    Just (_, i) -> return i

pp :: WeakTermPlus -> WithEnv ()
pp e = liftIO $ TIO.putStrLn $ toText e

piUnivLevelsfrom ::
     [Data.WeakTerm.IdentifierPlus] -> WeakTermPlus -> WithEnv [UnivLevelPlus]
piUnivLevelsfrom xts t = do
  let ms = map fst $ map (\(_, _, z) -> z) xts ++ [t]
  ls <- mapM (const newUnivLevel) ms
  return $ map UnivLevelPlus $ zip ms ls

insTypeEnv :: Identifier -> TermPlus -> UnivLevelPlus -> WithEnv ()
insTypeEnv (I (_, i)) t ml =
  modify (\e -> e {typeEnv = IntMap.insert i (t, ml) (typeEnv e)})

insTypeEnv' :: Identifier -> TermPlus -> WithEnv ()
insTypeEnv' (I (_, i)) t = do
  l <- newUnivLevel
  let ml = UnivLevelPlus (fst t, l)
  modify (\e -> e {typeEnv = IntMap.insert i (t, ml) (typeEnv e)})

lookupTypeEnv :: Identifier -> WithEnv (Maybe (TermPlus, UnivLevelPlus))
lookupTypeEnv (I (_, i)) = do
  tenv <- gets typeEnv
  return $ IntMap.lookup i tenv

lookupConstNum :: T.Text -> WithEnv Int
lookupConstNum constName = do
  cenv <- gets constantEnv
  case Map.lookup constName cenv of
    Just i -> return i
    Nothing -> do
      i <- newCount
      modify (\env -> env {constantEnv = Map.insert constName i cenv})
      return i

lookupConstNum' :: T.Text -> WithEnv Int
lookupConstNum' constName = do
  cenv <- gets constantEnv
  case Map.lookup constName cenv of
    Just i -> return i
    Nothing -> throwError' $ "no such constant: " <> constName

lookupConstantMaybe :: T.Text -> WithEnv (Maybe WeakTermPlus)
lookupConstantMaybe constName = do
  cenv <- gets constantEnv
  case Map.lookup constName cenv of
    Just i -> return $ Just (emptyMeta, WeakTermConst $ I (constName, i))
    Nothing -> return Nothing
      -- i <- newCount
      -- let ident = I (constName, i)
      -- modify (\env -> env {constantEnv = Map.insert constName i cenv})
      -- return $ Just (emptyMeta, WeakTermConst ident)

lookupConstantPlus :: T.Text -> WithEnv (Maybe WeakTermPlus)
lookupConstantPlus constName
  | isConstant constName = do
    cenv <- gets constantEnv
    case Map.lookup constName cenv of
      Just i -> return $ Just (emptyMeta, WeakTermConst $ I (constName, i))
      Nothing -> do
        i <- newCount
        let ident = I (constName, i)
        modify (\env -> env {constantEnv = Map.insert constName i cenv})
        return $ Just (emptyMeta, WeakTermConst ident)
  | otherwise = return Nothing

lookupConstantPlus' :: T.Text -> WithEnv WeakTermPlus
lookupConstantPlus' constName = do
  me <- lookupConstantPlus constName
  case me of
    Just e -> return e
    Nothing -> throwError' $ "no such constant: " <> constName

lookupFloat16 :: WithEnv WeakTermPlus
lookupFloat16 = lookupConstantPlus' "f16"

lookupFloat32 :: WithEnv WeakTermPlus
lookupFloat32 = lookupConstantPlus' "f32"

lookupFloat64 :: WithEnv WeakTermPlus
lookupFloat64 = lookupConstantPlus' "f64"
-- lookupConstant :: T.Text -> WithEnv WeakTermPlus
-- lookupConstant x
--   | isConstant x = lookupConstant
-- isConstant :: T.Text -> Bool
-- isConstant x
--   | Just (LowTypeFloat _) <- asLowTypeMaybe x = True
--   | Just _ <- asUnaryOpMaybe x = True
--   | Just _ <- asBinaryOpMaybe x = True
--   | otherwise = False
