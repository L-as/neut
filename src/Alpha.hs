module Alpha where

import           Control.Monad.State
import           Control.Monad.Trans.Except

import           Data

alpha :: MTerm -> WithEnv MTerm
alpha (Var s, i) = do
  t <- Var <$> alphaString s
  return (t, i)
alpha (Const s, i) = return (Const s, i)
alpha (Lam (s, t) e, i) = do
  t' <- alphaType t
  local $ do
    s' <- newNameWith s
    e' <- alpha e
    return (Lam (s', t') e', i)
alpha (App e v, i) = do
  e' <- alpha e
  v' <- alpha v
  return (App e' v', i)
alpha (Ret v, i) = do
  v' <- alpha v
  return (Ret v', i)
alpha (Bind (s, t) e1 e2, i) = do
  e1' <- alpha e1
  s' <- newNameWith s
  t' <- alphaType t
  e2' <- alpha e2
  return (Bind (s', t') e1' e2', i)
alpha (Thunk e, i) = do
  e' <- alpha e
  return (Thunk e', i)
alpha (Unthunk v, i) = do
  v' <- alpha v
  return (Unthunk v', i)
alpha (Mu (s, t) e, i) = do
  t' <- alphaType t
  local $ do
    s' <- newNameWith s
    e' <- alpha e
    return (Mu (s', t') e', i)
alpha (Case e ves, i) = do
  e' <- alpha e
  ves' <-
    forM ves $ \(pat, body) ->
      local $ do
        env <- get
        patEnvOrErr <- liftIO $ runWithEnv (alphaPat pat) (env {nameEnv = []})
        case patEnvOrErr of
          Left err -> lift $ throwE err
          Right (pat', env') -> do
            put
              (env {nameEnv = nameEnv env' ++ nameEnv env, count = count env'})
            body' <- alpha body
            return (pat', body')
  return (Case e' ves', i)
alpha (Asc e t, i) = do
  e' <- alpha e
  t' <- alphaType t
  return (Asc e' t', i)

alphaType :: Type -> WithEnv Type
alphaType (TVar s) = TVar <$> alphaString s
alphaType (THole i) = return (THole i)
alphaType (TConst s) = return (TConst s)
alphaType (TUp t) = TUp <$> alphaType t
alphaType (TDown t) = TDown <$> alphaType t
alphaType (TUniv level) = return (TUniv level)
alphaType (TForall (s, tdom) tcod) = do
  tdom' <- alphaType tdom
  local $ do
    s' <- newNameWith s
    tcod' <- alphaType tcod
    return (TForall (s', tdom') tcod')

alphaString :: String -> WithEnv String
alphaString s = do
  env <- get
  case lookup s (nameEnv env) of
    Just s' -> return s'
    Nothing -> lift $ throwE $ "undefined variable: " ++ show s

alphaPat :: MTerm -> WithEnv MTerm
alphaPat (Var s, i) = do
  t <- Var <$> alphaPatString s
  return (t, i)
alphaPat (Const s, i) = return (Const s, i)
alphaPat _ = lift $ throwE "Alpha.alphaPat"

alphaPatString :: String -> WithEnv String
alphaPatString s = do
  env <- get
  case lookup s (nameEnv env) of
    Just s' -> return s'
    Nothing -> newNameWith s
