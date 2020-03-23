{-# LANGUAGE OverloadedStrings #-}

module Parse.Discern
  ( discern
  ) where

import Control.Monad.Except
import Control.Monad.State

import qualified Data.HashMap.Strict as Map
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Text as T

import Data.Basic
import Data.Env
import Data.WeakTerm

discern :: [QuasiStmt] -> WithEnv [QuasiStmt]
discern = discern' Map.empty

type NameEnv = Map.HashMap T.Text Identifier

discern' :: NameEnv -> [QuasiStmt] -> WithEnv [QuasiStmt]
discern' _ [] = return []
discern' nenv ((QuasiStmtLet m (mx, x, t) e):ss) = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith' m nenv x
  e' <- discern'' nenv e
  ss' <- discern' (insertName x x' nenv) ss
  return $ QuasiStmtLet m (mx, x', t') e' : ss'
discern' nenv ((QuasiStmtLetWT m (mx, x, t) e):ss) = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith' m nenv x
  e' <- discern'' nenv e
  ss' <- discern' (insertName x x' nenv) ss
  return $ QuasiStmtLetWT m (mx, x', t') e' : ss'
discern' nenv (QuasiStmtLetSigma m xts e:ss) = do
  e' <- discern'' nenv e
  (xts', ss') <- discernStmtBinder nenv xts ss
  return $ QuasiStmtLetSigma m xts' e' : ss'
discern' nenv ((QuasiStmtDef xds):ss) = do
  let (xs, ds) = unzip xds
  -- discern for deflist
  let mys = map (\(_, (my, y, _), _, _) -> (my, y)) ds
  ys' <- mapM (\(my, y) -> newLLVMNameWith' my nenv y) mys
  let yis = map (asText . snd) mys
  let nenvForDef = Map.fromList (zip yis ys') `Map.union` nenv
  ds' <- mapM (discernDef nenvForDef) ds
  -- discern for continuation
  xs' <- mapM newLLVMNameWith xs
  let xis = map asText xs
  let nenvForCont = Map.fromList (zip xis xs') `Map.union` nenv
  ss' <- discern' nenvForCont ss
  return $ QuasiStmtDef (zip xs' ds') : ss'
discern' nenv ((QuasiStmtConstDecl m (mx, x, t)):ss) = do
  t' <- discern'' nenv t
  ss' <- discern' nenv ss
  return $ QuasiStmtConstDecl m (mx, x, t') : ss'
discern' nenv ((QuasiStmtImplicit m x i):ss) = do
  cenv <- gets constantEnv
  x' <-
    case Map.lookup (asText x) cenv of
      Just j -> return $ I (asText x, j)
      Nothing -> lookupName' m x nenv
  ss' <- discern' nenv ss
  return $ QuasiStmtImplicit m x' i : ss'
discern' nenv ((QuasiStmtLetInductive n m (mx, a, t) e):ss) = do
  t' <- discern'' nenv t
  a' <- newLLVMNameWith' m nenv a
  e' <- discern'' nenv e
  ss' <- discern' (insertName a a' nenv) ss
  return $ QuasiStmtLetInductive n m (mx, a', t') e' : ss'
discern' nenv ((QuasiStmtLetCoinductive n m (mx, a, t) e):ss) = do
  t' <- discern'' nenv t
  a' <- newLLVMNameWith' m nenv a
  e' <- discern'' nenv e
  ss' <- discern' (insertName a a' nenv) ss
  return $ QuasiStmtLetCoinductive n m (mx, a', t') e' : ss'
discern' nenv ((QuasiStmtLetInductiveIntro m enumInfo (mb, b, t) xts yts ats bts bInner _ _):ss) = do
  t' <- discern'' nenv t
  (xts', nenv') <- discernArgs nenv xts
  (yts', nenv'') <- discernArgs nenv' yts
  (ats', nenv''') <- discernArgs nenv'' ats
  (bts', nenv'''') <- discernArgs nenv''' bts
  bInner' <- discern'' nenv'''' bInner
  b' <- newLLVMNameWith' m nenv b
  ss' <- discern' (insertName b b' nenv) ss
  asOuter <- mapM (lookupStrict nenv) ats
  asInnerPlus <- mapM (lookupStrict' nenv'''') ats
  let info = zip asOuter asInnerPlus
  return $
    QuasiStmtLetInductiveIntro
      m
      enumInfo
      (mb, b', t')
      xts'
      yts'
      ats'
      bts'
      bInner'
      info
      asOuter :
    ss'
discern' nenv ((QuasiStmtLetCoinductiveElim m (mb, b, t) xtsyt codInner ats bts yt e1 e2 _ _):ss) = do
  t' <- discern'' nenv t
  (xtsyt', nenv') <- discernArgs nenv xtsyt
  e1' <- discern'' nenv' e1
  (ats', nenv'') <- discernArgs nenv' ats
  (bts', nenv''') <- discernArgs nenv'' bts
  (yt', nenv'''') <- discernIdentPlus' nenv''' yt
  codInner' <- discern'' nenv'''' codInner
  e2' <- discern'' nenv'''' e2
  b' <- newLLVMNameWith' m nenv b
  ss' <- discern' (insertName b b' nenv) ss
  asOuterPlus <- mapM (lookupStrict' nenv) ats
  asOuter <- mapM (lookupStrict nenv) ats
  asInner <- mapM (lookupStrict nenv'''') ats
  let info = zip asInner asOuterPlus
  return $
    QuasiStmtLetCoinductiveElim
      m
      (mb, b', t')
      xtsyt'
      codInner'
      ats'
      bts'
      yt'
      e1'
      e2'
      info
      asOuter :
    ss'

discernStmtBinder ::
     NameEnv
  -> [IdentifierPlus]
  -> [QuasiStmt]
  -> WithEnv ([IdentifierPlus], [QuasiStmt])
discernStmtBinder nenv [] ss = do
  ss' <- discern' nenv ss
  return ([], ss')
discernStmtBinder nenv ((mx, x, t):xts) ss = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith x
  (xts', ss') <- discernStmtBinder (insertName x x' nenv) xts ss
  return ((mx, x', t') : xts', ss')

discernDef :: NameEnv -> Def -> WithEnv Def
discernDef nenv (m, (mx, x, t), xts, e) = do
  t' <- discern'' nenv t
  (xts', e') <- discernBinder nenv xts e
  x' <- lookupName' mx x nenv
  return (m, (mx, x', t'), xts', e')

-- Alpha-convert all the variables so that different variables have different names.
discern'' :: NameEnv -> WeakTermPlus -> WithEnv WeakTermPlus
discern'' _ (m, WeakTermTau l) = return (m, WeakTermTau l)
discern'' nenv (m, WeakTermUpsilon x@(I (s, _))) = do
  b1 <- isDefinedEnumValue s
  b2 <- isDefinedEnumType s
  mc <- lookupConstantMaybe m s
  case (lookupName x nenv, b1, b2, mc) of
    (Just x', _, _, _) -> return (m, WeakTermUpsilon x')
    (_, True, _, _) -> return (m, WeakTermEnumIntro (EnumValueLabel s))
    (_, _, True, _) -> return (m, WeakTermEnum (EnumTypeLabel s))
    (_, _, _, Just c) -> return c
    _ -> raiseError m $ "undefined variable: " <> s
discern'' nenv (m, WeakTermPi mls xts t) = do
  (xts', t') <- discernBinder nenv xts t
  return (m, WeakTermPi mls xts' t')
discern'' nenv (m, WeakTermPiPlus name mls xts t) = do
  (xts', t') <- discernBinder nenv xts t
  return (m, WeakTermPiPlus name mls xts' t')
discern'' nenv (m, WeakTermPiIntro xts e) = do
  (xts', e') <- discernBinder nenv xts e
  return (m, WeakTermPiIntro xts' e')
discern'' nenv (m, WeakTermPiIntroNoReduce xts e) = do
  (xts', e') <- discernBinder nenv xts e
  return (m, WeakTermPiIntroNoReduce xts' e')
discern'' nenv (m, WeakTermPiIntroPlus ind (name, args) xts e) = do
  args' <- mapM (discernIdentPlus nenv) args
  (xts', e') <- discernBinder nenv xts e
  return (m, WeakTermPiIntroPlus ind (name, args') xts' e')
discern'' nenv (m, WeakTermPiElim e es) = do
  es' <- mapM (discern'' nenv) es
  e' <- discern'' nenv e
  return (m, WeakTermPiElim e' es')
discern'' nenv (m, WeakTermSigma xts) = do
  xts' <- discernSigma nenv xts
  return (m, WeakTermSigma xts')
discern'' nenv (m, WeakTermSigmaIntro t es) = do
  t' <- discern'' nenv t
  es' <- mapM (discern'' nenv) es
  return (m, WeakTermSigmaIntro t' es')
discern'' nenv (m, WeakTermSigmaElim t xts e1 e2) = do
  t' <- discern'' nenv t
  e1' <- discern'' nenv e1
  (xts', e2') <- discernBinder nenv xts e2
  return (m, WeakTermSigmaElim t' xts' e1' e2')
discern'' nenv (m, WeakTermIter xt xts e) = do
  (xt', xts', e') <- discernIter nenv xt xts e
  return (m, WeakTermIter xt' xts' e')
discern'' _ (m, WeakTermConst x) = return (m, WeakTermConst x)
discern'' _ (m, WeakTermZeta h) = do
  return (m, WeakTermZeta h)
discern'' nenv (m, WeakTermInt t x) = do
  t' <- discern'' nenv t
  return (m, WeakTermInt t' x)
discern'' _ (m, WeakTermFloat16 x) = return (m, WeakTermFloat16 x)
discern'' _ (m, WeakTermFloat32 x) = return (m, WeakTermFloat32 x)
discern'' _ (m, WeakTermFloat64 x) = return (m, WeakTermFloat64 x)
discern'' nenv (m, WeakTermFloat t x) = do
  t' <- discern'' nenv t
  return (m, WeakTermFloat t' x)
discern'' _ (m, WeakTermEnum s) = return (m, WeakTermEnum s)
discern'' _ (m, WeakTermEnumIntro x) = return (m, WeakTermEnumIntro x)
discern'' nenv (m, WeakTermEnumElim (e, t) caseList) = do
  e' <- discern'' nenv e
  t' <- discern'' nenv t
  caseList' <- discernCaseList nenv caseList
  return (m, WeakTermEnumElim (e', t') caseList')
discern'' nenv (m, WeakTermArray dom kind) = do
  dom' <- discern'' nenv dom
  return (m, WeakTermArray dom' kind)
discern'' nenv (m, WeakTermArrayIntro kind es) = do
  es' <- mapM (discern'' nenv) es
  return (m, WeakTermArrayIntro kind es')
discern'' nenv (m, WeakTermArrayElim kind xts e1 e2) = do
  e1' <- discern'' nenv e1
  (xts', e2') <- discernBinder nenv xts e2
  return (m, WeakTermArrayElim kind xts' e1' e2')
discern'' _ (m, WeakTermStruct ts) = return (m, WeakTermStruct ts)
discern'' nenv (m, WeakTermStructIntro ets) = do
  let (es, ts) = unzip ets
  es' <- mapM (discern'' nenv) es
  return (m, WeakTermStructIntro $ zip es' ts)
discern'' nenv (m, WeakTermStructElim xts e1 e2) = do
  e1' <- discern'' nenv e1
  (xts', e2') <- discernStruct nenv xts e2
  return (m, WeakTermStructElim xts' e1' e2')
discern'' nenv (m, WeakTermCase (e, t) cxtes) = do
  e' <- discern'' nenv e
  t' <- discern'' nenv t
  cxtes' <-
    flip mapM cxtes $ \((c, xts), body) -> do
      c' <- lookupName' m c nenv
      label <- lookupLLVMEnumEnv m (asText c)
      renv <- gets revCaseEnv
      modify (\env -> env {revCaseEnv = IntMap.insert (asInt c') label renv})
      (xts', body') <- discernBinder nenv xts body
      return ((c', xts'), body')
  return (m, WeakTermCase (e', t') cxtes')

discernBinder ::
     NameEnv
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WithEnv ([IdentifierPlus], WeakTermPlus)
discernBinder nenv [] e = do
  e' <- discern'' nenv e
  return ([], e')
discernBinder nenv ((mx, x, t):xts) e = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith x
  (xts', e') <- discernBinder (insertName x x' nenv) xts e
  return ((mx, x', t') : xts', e')

discernSigma :: NameEnv -> [IdentifierPlus] -> WithEnv [IdentifierPlus]
discernSigma _ [] = return []
discernSigma nenv ((mx, x, t):xts) = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith x
  xts' <- discernSigma (insertName x x' nenv) xts
  return $ (mx, x', t') : xts'

discernArgs ::
     NameEnv -> [IdentifierPlus] -> WithEnv ([IdentifierPlus], NameEnv)
discernArgs nenv [] = return ([], nenv)
discernArgs nenv ((mx, x, t):xts) = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith x
  (xts', nenv') <- discernArgs (insertName x x' nenv) xts
  return ((mx, x', t') : xts', nenv')

discernIdentPlus :: NameEnv -> IdentifierPlus -> WithEnv IdentifierPlus
discernIdentPlus nenv (m, x, t) = do
  t' <- discern'' nenv t
  x' <- lookupName' m x nenv
  return (m, x', t')

discernIdentPlus' ::
     NameEnv -> IdentifierPlus -> WithEnv (IdentifierPlus, NameEnv)
discernIdentPlus' nenv (m, x, t) = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith x
  return ((m, x', t'), insertName x x' nenv)

discernIter ::
     NameEnv
  -> IdentifierPlus
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WithEnv (IdentifierPlus, [IdentifierPlus], WeakTermPlus)
discernIter nenv (mx, x, t) xts e = do
  t' <- discern'' nenv t
  discernIter' nenv (mx, x, t') xts e

discernIter' ::
     NameEnv
  -> IdentifierPlus
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> WithEnv (IdentifierPlus, [IdentifierPlus], WeakTermPlus)
discernIter' nenv (mx, x, t') [] e = do
  x' <- newLLVMNameWith x
  e' <- discern'' (insertName x x' nenv) e
  return ((mx, x', t'), [], e')
discernIter' nenv xt ((mx, x, t):xts) e = do
  t' <- discern'' nenv t
  x' <- newLLVMNameWith x
  (xt', xts', e') <- discernIter' (insertName x x' nenv) xt xts e
  return (xt', (mx, x', t') : xts', e')

discernCaseList ::
     NameEnv -> [(WeakCase, WeakTermPlus)] -> WithEnv [(WeakCase, WeakTermPlus)]
discernCaseList nenv caseList =
  forM caseList $ \(l, body) -> do
    l' <- discernWeakCase nenv l
    body' <- discern'' nenv body
    return (l', body')

discernWeakCase :: NameEnv -> WeakCase -> WithEnv WeakCase
discernWeakCase nenv (WeakCaseInt t a) = do
  t' <- discern'' nenv t
  return (WeakCaseInt t' a)
discernWeakCase _ l = return l

discernStruct ::
     NameEnv
  -> [(Meta, Identifier, ArrayKind)]
  -> WeakTermPlus
  -> WithEnv ([(Meta, Identifier, ArrayKind)], WeakTermPlus)
discernStruct nenv [] e = do
  e' <- discern'' nenv e
  return ([], e')
discernStruct nenv ((mx, x, t):xts) e = do
  x' <- newLLVMNameWith x
  (xts', e') <- discernStruct (insertName x x' nenv) xts e
  return ((mx, x', t) : xts', e')

newLLVMNameWith :: Identifier -> WithEnv Identifier
newLLVMNameWith (I (s, _)) = do
  j <- newCount
  modify (\e -> e {nameEnv = Map.insert s s (nameEnv e)})
  return $ I (llvmString s, j)

newLLVMNameWith' :: Meta -> NameEnv -> Identifier -> WithEnv Identifier
newLLVMNameWith' m nenv x = do
  case Map.lookup (asText x) nenv of
    Nothing -> newLLVMNameWith x
    Just _ ->
      raiseError m $
      "the identifier `" <> asText x <> "` is already defined at top level"

lookupStrict :: NameEnv -> IdentifierPlus -> WithEnv Identifier
lookupStrict nenv (m, x, _) = lookupName' m x nenv

lookupStrict' :: NameEnv -> IdentifierPlus -> WithEnv WeakTermPlus
lookupStrict' nenv xt@(m, _, _) = do
  x' <- lookupStrict nenv xt
  return (m, WeakTermUpsilon x')

insertName :: Identifier -> Identifier -> NameEnv -> NameEnv
insertName (I (s, _)) y nenv = Map.insert s y nenv

lookupName :: Identifier -> NameEnv -> Maybe Identifier
lookupName (I (s, _)) nenv = Map.lookup s nenv

lookupName' :: Meta -> Identifier -> NameEnv -> WithEnv Identifier
lookupName' m x nenv = do
  case lookupName x nenv of
    Just x' -> return x'
    Nothing -> raiseError m $ "undefined variable:  " <> asText x