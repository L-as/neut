-- This module "polarizes" a neutral term into a negMetaative term. Operationally,
-- this corresponds to determination of the order of evaluation. In proof-theoretic
-- term, we translate a ordinary dependent calculus to a dependent variant of
-- Call-By-Push-Value, although this translation doesn't preserve types when the
-- given term includes dependent sigma-elimination. A detailed explanation of
-- Call-By-Push-Value can be found in P. Levy, "Call-by-Push-Value: A Subsuming
-- Paradigm". Ph. D. thesis, Queen Mary College, 2001.
module Polarize
  ( polarize
  ) where

import           Control.Monad.Except
import           Control.Monad.State
import           Data.List            (nubBy)
import           Prelude              hiding (pi)

import           Data.Basic
import           Data.Code
import           Data.Env
import           Data.Term

polarize :: TermPlus -> WithEnv CodePlus
polarize (_, TermTau) = exponentTrivial
polarize (m, TermTheta x) = polarizeTheta m x
polarize (m, TermUpsilon x) = do
  (y, yts) <- polarize' $ fst $ obtainInfoMeta m
  let ml = snd $ obtainInfoMeta m
  bindLet yts (negMeta (up y ml) ml, CodeUpIntro (posMeta y ml, DataUpsilon x))
polarize (_, TermEpsilon _) = exponentTrivial
polarize (m, TermEpsilonIntro l) = do
  (u, ues) <- polarize' $ fst $ obtainInfoMeta m
  let ml = snd $ obtainInfoMeta m
  bindLet
    ues
    (negMeta (up u ml) ml, CodeUpIntro (posMeta u ml, DataEpsilonIntro l))
polarize (m, TermEpsilonElim (x, t) e bs) = do
  (u, uts) <- polarize' $ fst $ obtainInfoMeta m
  let ml = snd $ obtainInfoMeta m
  let (cs, es) = unzip bs
  es' <- mapM polarize es
  (y, yts) <- polarize' e
  (z, zts) <- polarize' t
  bindLet
    (uts ++ yts ++ zts)
    (negMeta (up u ml) ml, CodeEpsilonElim (x, z) y (zip cs es'))
polarize (m, TermPi _ _) = do
  (u, uts) <- polarize' $ fst $ obtainInfoMeta m
  let ml = snd $ obtainInfoMeta m
  clsExp <- exponentClosure
  bindLet uts (negMeta (up u ml) ml, CodeUpIntro clsExp)
polarize (m, TermPiIntro xts e) = do
  e' <- polarize e
  lamName <- newNameWith "theta"
  makeClosure lamName m (map fst xts) e'
polarize (m, TermPiElim e es) = do
  e' <- polarize e
  callClosure m e' es
polarize (m, TermMu (f, t) e) = do
  let ml = snd $ obtainInfoMeta m
  let vs = nubBy (\x y -> fst x == fst y) $ varTermPlus e
  let (xs, _) = unzip vs
  let vs' = map toTermVar vs
  let clsMuType = (MetaTerminal ml, TermPi vs t)
  let lamBody =
        substTermPlus
          [ ( f
            , ( MetaNonTerminal t ml
              , TermPiElim (MetaNonTerminal clsMuType ml, TermTheta f) vs'))
          ]
          e
  lamBody' <- polarize lamBody
  let clsMeta = MetaNonTerminal clsMuType ml
  cls <- makeClosure f clsMeta xs lamBody'
  callClosure m cls vs'

makeClosure ::
     Identifier -> Meta -> [Identifier] -> CodePlus -> WithEnv CodePlus
makeClosure lamThetaName m xps e = do
  let ml = snd $ obtainInfoMeta m
  let fvs = nubBy (\x y -> fst x == fst y) $ varCodePlus e
  -- envType = (C1, ..., Cn), where Ci is the types of the free variables in e'
  envExp <- exponentSigma $ map (Left . snd) fvs
  (envVarName, envVar) <- newVarOfType envExp
  let codType = fst $ obtainInfoCodeMeta $ fst e
  let lamBody = (negMeta codType ml, CodeSigmaElim (map fst fvs) envVar e)
  triv <- exponentTrivialLabel
  let lamTheta = (posMeta triv ml, DataTheta lamThetaName)
  penv <- gets polEnv
  when (lamThetaName `elem` map fst penv) $
    insPolEnv lamThetaName (envVarName : xps) lamBody
  let fvSigmaIntro = (posMeta envExp ml, DataSigmaIntro $ map toVar fvs)
  clsExp <- exponentClosure
  return
    ( negMeta (up clsExp ml) ml
    , CodeUpIntro
        (posMeta clsExp ml, DataSigmaIntro [envExp, fvSigmaIntro, lamTheta]))

callClosure :: Meta -> CodePlus -> [TermPlus] -> WithEnv CodePlus
callClosure m e es = do
  (xs, xes) <- unzip <$> mapM polarize' es
  (u, ues) <- polarize' $ fst $ obtainInfoMeta m
  let ml = snd $ obtainInfoMeta m
  -- ts <- mapM typeOf es'
  triv <- exponentTrivialLabel
  clsType <- exponentClosure
  -- argList <- mapM newVarOfType ts
  (clsVarName, clsVar) <- newVarOfType clsType
  (typeVarName, typeVar) <- newVarOfType triv
  (envVarName, envVar) <- newVarOfType typeVar
  (lamVarName, lamVar) <- newVarOfType triv
  cont <-
    bindLet
      (concat xes)
      ( negMeta (up u ml) ml
      , CodeSigmaElim
          [typeVarName, envVarName, lamVarName]
          clsVar
          (negMeta (up u ml) ml, CodePiElimDownElim lamVar (envVar : xs)))
  bindLet ues (negMeta (up u ml) ml, CodeUpElim clsVarName e cont)

toVar :: (Identifier, DataPlus) -> DataPlus
toVar (x, t) = do
  let (_, ml) = obtainInfoDataMeta $ fst t
  (DataMetaNonTerminal t ml, DataUpsilon x)

toTermVar :: (Identifier, TermPlus) -> TermPlus
toTermVar (x, t) = do
  let (_, ml) = obtainInfoMeta $ fst t
  (MetaNonTerminal t ml, TermUpsilon x)

-- 「DataPlusを使えるのは、[(Identifier, CodePlus)]をすべてbindしてから」
polarize' :: TermPlus -> WithEnv (DataPlus, [(Identifier, CodePlus)])
polarize' e@(m, _) = do
  e' <- polarize e
  case m of
    MetaTerminal ml -> do
      let triv = (DataMetaTerminal ml, DataTheta "THETA")
      (varName, var) <- newVarOfType' triv ml
      return (var, [(varName, e')])
    MetaNonTerminal t ml -> do
      (p, xes) <- polarize' t
      (varName, var) <- newVarOfType' p ml
      return (var, xes ++ [(varName, e')])

bindLet :: [(Identifier, CodePlus)] -> CodePlus -> WithEnv CodePlus
bindLet [] cont = return cont
bindLet ((x, e):xes) cont = do
  e' <- bindLet xes cont
  let (typeOfCont, ml) = obtainInfoCodeMeta $ fst e'
  -- kleisli extension (i.e. dependent up-elimination)
  let ke = (fst typeOfCont, CodeUpElim x e typeOfCont)
  return (negMeta ke ml, CodeUpElim x e e')

posMeta :: DataPlus -> Maybe (Int, Int) -> DataMeta
posMeta = DataMetaNonTerminal

negMeta :: CodePlus -> Maybe (Int, Int) -> CodeMeta
negMeta = CodeMetaNonTerminal

up :: DataPlus -> Maybe (Int, Int) -> CodePlus
up u ml = (CodeMetaTerminal ml, CodeUp u)

-- return LABEL_OF_TRIVAL_EXPONENT
-- (LABEL_OF_TRIVAL_EXPONENT ~> lam (n, x). (x, ..., x))
exponentTrivialLabel :: WithEnv DataPlus
exponentTrivialLabel = return (DataMetaTerminal Nothing, DataTheta "_TRIVIAL_")

exponentTrivial :: WithEnv CodePlus
exponentTrivial = do
  triv <- exponentTrivialLabel
  return (negMeta (up triv Nothing) Nothing, CodeUpIntro triv)

supplyName :: Either b (Identifier, b) -> WithEnv (Identifier, b)
supplyName (Left t) = do
  x <- newNameWith "hole"
  return (x, t)
supplyName (Right (x, t)) = return (x, t)

-- Sigma (y1 : t1, ..., yn : tn) ~>
--   lam (n, z).
--     let (y1, ..., yn) := z in
--     bind ys1 = t1 @ (n, y1) in
--     ...
--     bind ysn = tn @ (n, yn) in
--     ((ys1[0], ..., ysm[0]), ..., (ys1[n], ..., ysm[n]))
--
-- (Note that Sigma (y1 : t1, ..., yn : tn) must be closed.)
exponentSigma :: [Either DataPlus (Identifier, DataPlus)] -> WithEnv DataPlus
exponentSigma mxts = do
  xts <- mapM supplyName mxts
  triv <- exponentTrivialLabel
  lamThetaName <- newNameWith "exp.sigma"
  (countVarName, countVar) <- newVarOfType triv -- int
  (sigVarName, sigVar) <- newVarOfType undefined -- sigma (IORefでlamThetaNameにすべき？)
  let lamBody =
        (undefined, CodeSigmaElim (map fst xts) sigVar (undefined xts countVar))
  insPolEnv lamThetaName [countVarName, sigVarName] lamBody
  return (posMeta triv Nothing, DataTheta lamThetaName)

-- FIXME: 使い回すように変更
exponentClosure :: WithEnv DataPlus
exponentClosure = do
  triv <- exponentTrivialLabel
  (typeVarName, typeVar) <- newVarOfType triv
  exponentSigma [Right (typeVarName, triv), Left typeVar, Left triv]

-- expand definitions of constants
polarizeTheta :: Meta -> Identifier -> WithEnv CodePlus
polarizeTheta m name@"core.i8.add"    = polarizeThetaArith name ArithAdd m
polarizeTheta m name@"core.i16.add"   = polarizeThetaArith name ArithAdd m
polarizeTheta m name@"core.i32.add"   = polarizeThetaArith name ArithAdd m
polarizeTheta m name@"core.i64.add"   = polarizeThetaArith name ArithAdd m
polarizeTheta m name@"core.i8.sub"    = polarizeThetaArith name ArithSub m
polarizeTheta m name@"core.i16.sub"   = polarizeThetaArith name ArithSub m
polarizeTheta m name@"core.i32.sub"   = polarizeThetaArith name ArithSub m
polarizeTheta m name@"core.i64.sub"   = polarizeThetaArith name ArithSub m
polarizeTheta m name@"core.i8.mul"    = polarizeThetaArith name ArithMul m
polarizeTheta m name@"core.i16.mul"   = polarizeThetaArith name ArithMul m
polarizeTheta m name@"core.i32.mul"   = polarizeThetaArith name ArithMul m
polarizeTheta m name@"core.i64.mul"   = polarizeThetaArith name ArithMul m
polarizeTheta m name@"core.i8.div"    = polarizeThetaArith name ArithDiv m
polarizeTheta m name@"core.i16.div"   = polarizeThetaArith name ArithDiv m
polarizeTheta m name@"core.i32.div"   = polarizeThetaArith name ArithDiv m
polarizeTheta m name@"core.i64.div"   = polarizeThetaArith name ArithDiv m
polarizeTheta m name@"core.f32.add"   = polarizeThetaArith name ArithAdd m
polarizeTheta m name@"core.f64.add"   = polarizeThetaArith name ArithAdd m
polarizeTheta m name@"core.f32.sub"   = polarizeThetaArith name ArithSub m
polarizeTheta m name@"core.f64.sub"   = polarizeThetaArith name ArithSub m
polarizeTheta m name@"core.f32.mul"   = polarizeThetaArith name ArithMul m
polarizeTheta m name@"core.f64.mul"   = polarizeThetaArith name ArithMul m
polarizeTheta m name@"core.f32.div"   = polarizeThetaArith name ArithDiv m
polarizeTheta m name@"core.f64.div"   = polarizeThetaArith name ArithDiv m
polarizeTheta m name@"core.print.i64" = polarizeThetaPrint name m
polarizeTheta _ _                     = throwError "polarize.theta"

polarizeThetaArith :: Identifier -> Arith -> Meta -> WithEnv CodePlus
polarizeThetaArith name op m
  -- (_, _, ml) <- polarizeMeta m
  -- (u, ue) <- polarize' $ fst $ obtainInfoMeta m
 = do
  let ml = snd $ obtainInfoMeta m
  numExp <- exponentTrivialLabel
  (x, varX) <- newVarOfType numExp
  (y, varY) <- newVarOfType numExp
  makeClosure
    name
    m
    [x, y]
    (negMeta (up numExp ml) ml, CodeTheta (ThetaArith op varX varY))

polarizeThetaPrint :: Identifier -> Meta -> WithEnv CodePlus
polarizeThetaPrint name m
  -- (_, _, ml) <- polarizeMeta m
  -- (u, ue) <- polarize' $ fst $ obtainInfoMeta m
 = do
  let ml = snd $ obtainInfoMeta m
  intExp <- exponentTrivialLabel
  codExp <- exponentTrivial
  (x, varX) <- newVarOfType intExp
  makeClosure name m [x] (negMeta codExp ml, CodeTheta (ThetaPrint varX))

newVarOfType :: DataPlus -> WithEnv (Identifier, DataPlus)
newVarOfType t = do
  x <- newNameWith "arg"
  return (x, (posMeta t Nothing, DataUpsilon x))

newVarOfType' :: DataPlus -> Maybe (Int, Int) -> WithEnv (Identifier, DataPlus)
newVarOfType' t ml = do
  x <- newNameWith "arg"
  return (x, (posMeta t ml, DataUpsilon x))
