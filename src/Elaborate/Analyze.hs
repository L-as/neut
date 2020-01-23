{-# LANGUAGE OverloadedStrings #-}

module Elaborate.Analyze
  ( analyze
  , simp
  , toPiElim
  , linearCheck
  , unfoldIter
  , toVarList
  , bindFormalArgs
  , lookupAny
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.List
import Data.Maybe
import System.Timeout

import qualified Data.HashMap.Strict as Map
import qualified Data.PQueue.Min as Q
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Text.Show.Pretty as Pr

import Data.Basic
import Data.Constraint
import Data.Env
import Data.WeakTerm
import Reduce.WeakTerm

-- {} analyze {}
analyze :: WithEnv ()
analyze = do
  cs <- gets constraintEnv
  simp cs

-- {} simp {}
simp :: [PreConstraint] -> WithEnv ()
simp [] = return ()
simp ((e1, e2):cs) = do
  me1' <- return (reduceWeakTermPlus e1) >>= liftIO . timeout 5000000 . return
  me2' <- return (reduceWeakTermPlus e2) >>= liftIO . timeout 5000000 . return
  case (me1', me2') of
    (Just e1', Just e2') -> simp' $ (e1', e2') : cs
    _ ->
      throwError $ "cannot simplify [TIMEOUT]:\n" <> T.pack (Pr.ppShow (e1, e2))

-- {} simp' {}
simp' :: [PreConstraint] -> WithEnv ()
simp' [] = return ()
simp' (((_, e1), (_, e2)):cs)
  | e1 == e2 = simp cs
simp' (((_, WeakTermPi xts1 cod1), (_, WeakTermPi xts2 cod2)):cs)
  | length xts1 == length xts2 = simpBinder xts1 cod1 xts2 cod2 cs
simp' (((_, WeakTermPiIntro xts1 e1), (_, WeakTermPiIntro xts2 e2)):cs)
  | length xts1 == length xts2 = simpBinder xts1 e1 xts2 e2 cs
simp' (((_, WeakTermPiIntro xts body1@(m1, _)), e2@(_, _)):cs) = do
  let vs = map (toVar . fst) xts
  simp $ (body1, (m1, WeakTermPiElim e2 vs)) : cs
simp' ((e1, e2@(_, WeakTermPiIntro {})):cs) = simp' $ (e2, e1) : cs
simp' (((_, WeakTermIter xt1 xts1 e1), (_, WeakTermIter xt2 xts2 e2)):cs)
  | fst xt1 == fst xt2
  , length xts1 == length xts2 = simpBinder (xt1 : xts1) e1 (xt2 : xts2) e2 cs
simp' (((_, WeakTermConstDecl xt1 e1), (_, WeakTermConstDecl xt2 e2)):cs) = do
  simpBinder [xt1] e1 [xt2] e2 cs
simp' (((_, WeakTermInt t1 l1), (_, WeakTermEnumIntro (EnumValueIntS s2 l2))):cs)
  | l1 == l2 = simp $ (t1, toIntS s2) : cs
simp' (((_, WeakTermEnumIntro (EnumValueIntS s1 l1)), (_, WeakTermInt t2 l2)):cs)
  | l1 == l2 = simp $ (toIntS s1, t2) : cs
simp' (((_, WeakTermInt t1 l1), (_, WeakTermEnumIntro (EnumValueIntU s2 l2))):cs)
  | l1 == l2 = simp $ (t1, toIntU s2) : cs
simp' (((_, WeakTermEnumIntro (EnumValueIntU s1 l1)), (_, WeakTermInt t2 l2)):cs)
  | l1 == l2 = simp $ (toIntU s1, t2) : cs
simp' (((_, WeakTermInt t1 l1), (_, WeakTermInt t2 l2)):cs)
  | l1 == l2 = simp $ (t1, t2) : cs
simp' (((_, WeakTermFloat t1 l1), (_, WeakTermFloat16 l2)):cs)
  | show l1 == show l2 = simp $ (t1, f16) : cs
simp' (((_, WeakTermFloat16 l1), (_, WeakTermFloat t2 l2)):cs)
  | show l1 == show l2 = simp $ (f16, t2) : cs
simp' (((_, WeakTermFloat t1 l1), (_, WeakTermFloat32 l2)):cs)
  | show l1 == show l2 = simp $ (t1, f32) : cs
simp' (((_, WeakTermFloat32 l1), (_, WeakTermFloat t2 l2)):cs)
  | show l1 == show l2 = simp $ (f32, t2) : cs
simp' (((_, WeakTermFloat t1 l1), (_, WeakTermFloat64 l2)):cs)
  | l1 == l2 = simp $ (t1, f64) : cs
simp' (((_, WeakTermFloat64 l1), (_, WeakTermFloat t2 l2)):cs)
  | l1 == l2 = simp $ (f64, t2) : cs
simp' (((_, WeakTermFloat t1 l1), (_, WeakTermFloat t2 l2)):cs)
  | l1 == l2 = simp $ (t1, t2) : cs
simp' (((_, WeakTermEnumElim (e1, t1) les1), (_, WeakTermEnumElim (e2, t2) les2)):cs)
  -- using term equality
  | e1 == e2 = do
    simpCase les1 les2
    simp $ (t1, t2) : cs
simp' (((_, WeakTermArray dom1 k1), (_, WeakTermArray dom2 k2)):cs)
  | k1 == k2 = simp $ (dom1, dom2) : cs
simp' (((_, WeakTermArrayIntro k1 es1), (_, WeakTermArrayIntro k2 es2)):cs)
  | k1 == k2
  , length es1 == length es2 = simp $ zip es1 es2 ++ cs
simp' (((_, WeakTermStructIntro eks1), (_, WeakTermStructIntro eks2)):cs)
  | (es1, ks1) <- unzip eks1
  , (es2, ks2) <- unzip eks2
  , ks1 == ks2 = simp $ zip es1 es2 ++ cs
simp' ((e1, e2):cs) = do
  let ms1 = asStuckedTerm e1
  let ms2 = asStuckedTerm e2
  -- list of stuck reasons (fmvs: free meta-variables)
  let fmvs = catMaybes [ms1 >>= stuckReasonOf, ms2 >>= stuckReasonOf]
  sub <- gets substEnv
  case lookupAny fmvs sub of
    Just (h, e) -> do
      let e1' = substWeakTermPlus [(h, e)] e1
      let e2' = substWeakTermPlus [(h, e)] e2
      simp $ (e1', e2') : cs
    Nothing -> do
      let hs1 = holeWeakTermPlus e1
      let hs2 = holeWeakTermPlus e2
      case (ms1, ms2) of
        (Just (StuckPiElimConst f1 ess1), Just (StuckPiElimConst f2 ess2))
          | f1 == f2
          , length ess1 == length ess2
          , es1 <- concat ess1
          , es2 <- concat ess2
          -- es1 = [[a, b], [c]], es2 =  [[d], [e, f]]とかを許してしまっているので修正すること
          , length es1 == length es2 -> simp $ zip es1 es2 ++ cs
        (Just (StuckPiElimIter iter1@(x1, _, _, _) mess1), Just (StuckPiElimIter (x2, _, _, _) mess2))
          | x1 == x2
          , length mess1 == length mess2
          , ess1 <- map snd mess1
          , ess2 <- map snd mess2
          , length (concat ess1) == length (concat ess2) -> do
            let c = Enriched (e1, e2) [] $ ConstraintDelta iter1 mess1 mess2
            insConstraintQueue c
            simp cs
        (Just (StuckPiElimIter iter1 mess1), Just (StuckPiElimIter iter2 mess2)) -> do
          let e1' = toPiElim (unfoldIter iter1) mess1
          let e2' = toPiElim (unfoldIter iter2) mess2
          simp $ (e1', e2') : cs
        (Just (StuckPiElimIter iter1 mess1), _) -> do
          simp $ (toPiElim (unfoldIter iter1) mess1, e2) : cs
        (_, Just (StuckPiElimIter iter2 mess2)) -> do
          simp $ (e1, toPiElim (unfoldIter iter2) mess2) : cs
        (Just (StuckPiElimZetaStrict h1 ies1), _)
          | xs1 <- concatMap getVarList ies1
          , occurCheck h1 hs2
          , includeCheck xs1 e2
          , linearCheck xs1 -> simpPattern h1 ies1 e1 e2 cs
        (_, Just (StuckPiElimZetaStrict h2 ies2))
          | xs2 <- concatMap getVarList ies2
          , occurCheck h2 hs1
          , includeCheck xs2 e1
          , linearCheck xs2 -> simpPattern h2 ies2 e2 e1 cs
        (Just (StuckUpsilon x1), _)
          | Just body <- Map.lookup x1 sub ->
            simp $ (substWeakTermPlus [(x1, body)] e1, e2) : cs
        (_, Just (StuckUpsilon x2))
          | Just body <- Map.lookup x2 sub ->
            simp $ (e1, substWeakTermPlus [(x2, body)] e2) : cs
        (Just (StuckPiElimZetaStrict h1 ies1), _)
          | xs1 <- concatMap getVarList ies1
          , occurCheck h1 hs2
          , includeCheck xs1 e2 -> simpQuasiPattern h1 ies1 e1 e2 fmvs cs
        (_, Just (StuckPiElimZetaStrict h2 ies2))
          | xs2 <- concatMap getVarList ies2
          , occurCheck h2 hs1
          , includeCheck xs2 e1 -> simpQuasiPattern h2 ies2 e2 e1 fmvs cs
        (Just (StuckPiElimZeta h1 ies1), Nothing)
          | xs1 <- concatMap getVarList ies1
          , occurCheck h1 hs2
          , includeCheck xs1 e2 -> simpFlexRigid h1 ies1 e1 e2 fmvs cs
        (Nothing, Just (StuckPiElimZeta h2 ies2))
          | xs2 <- concatMap getVarList ies2
          , occurCheck h2 hs1
          , includeCheck xs2 e1 -> simpFlexRigid h2 ies2 e2 e1 fmvs cs
        _ -> simpOther e1 e2 fmvs cs

-- {} simpBinder {}
simpBinder ::
     [(Identifier, WeakTermPlus)]
  -> WeakTermPlus
  -> [(Identifier, WeakTermPlus)]
  -> WeakTermPlus
  -> [(WeakTermPlus, WeakTermPlus)]
  -> WithEnv ()
simpBinder [] cod1 [] cod2 cs = simp $ (cod1, cod2) : cs
simpBinder ((x1, t1):xts1) cod1 ((x2, t2):xts2) cod2 cs = do
  let var1 = toVar x1
  let (xts2', cod2') = substWeakTermPlusBindingsWithBody [(x2, var1)] xts2 cod2
  simp [(t1, t2)]
  simpBinder xts1 cod1 xts2' cod2' cs
simpBinder _ _ _ _ _ = throwError "cannot simplify (simpBinder)"

-- {} simpCase {}
simpCase :: (Ord a) => [(a, WeakTermPlus)] -> [(a, WeakTermPlus)] -> WithEnv ()
simpCase les1 les2 = do
  let les1' = sortBy (\x y -> fst x `compare` fst y) les1
  let les2' = sortBy (\x y -> fst x `compare` fst y) les2
  let (ls1, es1) = unzip les1'
  let (ls2, es2) = unzip les2'
  if ls1 /= ls2
    then throwError "cannot simplify (simpCase)"
    else simp $ zip es1 es2

-- {} simpPattern {}
simpPattern ::
     Identifier
  -> [[WeakTermPlus]]
  -> WeakTermPlus
  -> WeakTermPlus
  -> [PreConstraint]
  -> WithEnv ()
simpPattern h1 ies1 _ e2 cs = do
  xss <- mapM toVarList ies1
  let lam = bindFormalArgs e2 xss
  modify (\env -> env {substEnv = Map.insert h1 lam (substEnv env)})
  visit h1
  simp cs

-- {} simpQuasiPattern {}
simpQuasiPattern ::
     Identifier
  -> [[WeakTermPlus]]
  -> WeakTermPlus
  -> WeakTermPlus
  -> [Identifier]
  -> [PreConstraint]
  -> WithEnv ()
simpQuasiPattern h1 ies1 e1 e2 fmvs cs = do
  insConstraintQueue $
    Enriched (e1, e2) fmvs (ConstraintQuasiPattern h1 ies1 e2)
  simp cs

-- {} simpFlexRigid {}
simpFlexRigid ::
     Hole
  -> [[WeakTermPlus]]
  -> WeakTermPlus
  -> WeakTermPlus
  -> [Identifier]
  -> [PreConstraint]
  -> WithEnv ()
simpFlexRigid h1 ies1 e1 e2 fmvs cs = do
  insConstraintQueue $ Enriched (e1, e2) fmvs (ConstraintFlexRigid h1 ies1 e2)
  simp cs

-- {} simpOther {}
simpOther ::
     WeakTermPlus -> WeakTermPlus -> [Hole] -> [PreConstraint] -> WithEnv ()
simpOther e1 e2 fmvs cs = do
  insConstraintQueue $ Enriched (e1, e2) fmvs $ ConstraintOther
  simp cs

data Stuck
  = StuckPiElimZeta Hole [[WeakTermPlus]]
  | StuckPiElimZetaStrict Hole [[WeakTermPlus]]
  | StuckPiElimIter IterInfo [(Meta, [WeakTermPlus])]
  | StuckPiElimConst Identifier [[WeakTermPlus]]
  | StuckUpsilon Identifier

-- {} asStuckedTerm {}
asStuckedTerm :: WeakTermPlus -> Maybe Stuck
asStuckedTerm (_, WeakTermUpsilon x) = Just $ StuckUpsilon x
asStuckedTerm (_, WeakTermPiElim (_, WeakTermZeta h) es)
  | Just _ <- mapM asUpsilon es = Just $ StuckPiElimZetaStrict h [es]
asStuckedTerm (_, WeakTermPiElim (_, WeakTermZeta h) es) =
  Just $ StuckPiElimZeta h [es]
asStuckedTerm (m, WeakTermPiElim self@(_, WeakTermIter (x, _) xts body) es) =
  Just $ StuckPiElimIter (x, xts, body, self) [(m, es)]
asStuckedTerm (_, WeakTermPiElim (_, WeakTermConst x) es) =
  Just $ StuckPiElimConst x [es]
asStuckedTerm (m, WeakTermPiElim e es)
  | Just _ <- mapM asUpsilon es =
    case asStuckedTerm e of
      Just (StuckPiElimZeta h iess) -> Just $ StuckPiElimZeta h (iess ++ [es])
      Just (StuckPiElimZetaStrict h iexss) ->
        Just $ StuckPiElimZetaStrict h $ iexss ++ [es]
      Just (StuckPiElimIter mu ess) ->
        Just $ StuckPiElimIter mu $ ess ++ [(m, es)]
      Just (StuckPiElimConst x ess) -> Just $ StuckPiElimConst x $ ess ++ [es]
      Just (StuckUpsilon x) -> Just $ StuckUpsilon x
      Nothing -> Nothing
asStuckedTerm (m, WeakTermPiElim e es) =
  case asStuckedTerm e of
    Just (StuckPiElimZeta h iess) -> Just $ StuckPiElimZeta h $ iess ++ [es]
    Just (StuckPiElimZetaStrict h iess) -> do
      Just $ StuckPiElimZeta h $ iess ++ [es]
    Just (StuckPiElimIter mu ess) ->
      Just $ StuckPiElimIter mu $ ess ++ [(m, es)]
    Just (StuckPiElimConst x ess) -> Just $ StuckPiElimConst x $ ess ++ [es]
    Just (StuckUpsilon x) -> Just $ StuckUpsilon x
    Nothing -> Nothing
asStuckedTerm (_, WeakTermEnumElim ((_, WeakTermUpsilon x), _) _) =
  Just $ StuckUpsilon x
asStuckedTerm _ = Nothing

-- {} stuckReasonOf {}
stuckReasonOf :: Stuck -> Maybe Hole
stuckReasonOf (StuckPiElimZeta h _) = Just h
stuckReasonOf (StuckPiElimZetaStrict h _) = Just h
stuckReasonOf (StuckPiElimIter {}) = Nothing
stuckReasonOf (StuckPiElimConst _ _) = Nothing
stuckReasonOf (StuckUpsilon _) = Nothing

-- {} occurCheck {}
occurCheck :: Identifier -> [Identifier] -> Bool
occurCheck h fmvs = h `notElem` fmvs

-- {} includeCheck {}
includeCheck :: [Identifier] -> WeakTermPlus -> Bool
includeCheck xs e = all (`elem` xs) $ varWeakTermPlus e

-- {} linearCheck {}
linearCheck :: [Identifier] -> Bool
linearCheck xs = linearCheck' S.empty xs

linearCheck' :: (S.Set Identifier) -> [Identifier] -> Bool
linearCheck' _ [] = True
linearCheck' found (x:_)
  | x `S.member` found = False
linearCheck' found (x:xs) = linearCheck' (S.insert x found) xs

-- {} getVarList {}
getVarList :: [WeakTermPlus] -> [Identifier]
getVarList xs = catMaybes $ map asUpsilon xs

-- {} asUpsilon {}
asUpsilon :: WeakTermPlus -> Maybe Identifier
asUpsilon (_, WeakTermUpsilon x) = Just x
asUpsilon _ = Nothing

-- {} toPiElim {}
toPiElim :: WeakTermPlus -> [(Meta, [WeakTermPlus])] -> WeakTermPlus
toPiElim e [] = e
toPiElim e ((m, es):ess) = toPiElim (m, WeakTermPiElim e es) ess

unfoldIter :: IterInfo -> WeakTermPlus
unfoldIter (x, xts, body, self) = do
  let body' = substWeakTermPlus [(x, self)] body
  (fst self, WeakTermPiIntro xts body')

insConstraintQueue :: EnrichedConstraint -> WithEnv ()
insConstraintQueue c = do
  modify (\env -> env {constraintQueue = Q.insert c (constraintQueue env)})

visit :: Identifier -> WithEnv ()
visit m = do
  q <- gets constraintQueue
  let (q1, q2) = Q.partition (\(Enriched _ ms _) -> m `elem` ms) q
  modify (\env -> env {constraintQueue = q2})
  simp $ map (\(Enriched c _ _) -> c) $ Q.toList q1

-- [e, x, y, y, e2, e3, z] ~> [p, x, y, y, q, r, z]  (p, q, r: new variables)
-- {} toVarList {}
toVarList :: [WeakTermPlus] -> WithEnv [(Identifier, WeakTermPlus)]
toVarList [] = return []
toVarList ((_, WeakTermUpsilon x):es) = do
  xts <- toVarList es
  let t = (emptyMeta, WeakTermUpsilon "DONT_CARE")
  return $ (x, t) : xts
toVarList (_:es) = do
  xts <- toVarList es
  x <- newNameWith "hole"
  let t = (emptyMeta, WeakTermUpsilon "DONT_CARE")
  return $ (x, t) : xts

bindFormalArgs :: WeakTermPlus -> [[IdentifierPlus]] -> WeakTermPlus
bindFormalArgs e [] = e
bindFormalArgs e (xts:xtss) = do
  let e' = bindFormalArgs e xtss
  (emptyMeta, WeakTermPiIntro xts e')

lookupAny :: [Hole] -> Map.HashMap Identifier a -> Maybe (Hole, a)
lookupAny [] _ = Nothing
lookupAny (h:ks) sub = do
  case Map.lookup h sub of
    Just v -> Just (h, v)
    _ -> lookupAny ks sub
