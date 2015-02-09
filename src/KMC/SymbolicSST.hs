{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
module KMC.SymbolicSST where

import           Control.Applicative
import           Control.Monad

import qualified Data.Set as S
import qualified Data.Map as M

import           KMC.Theories

type Valuation var delta       = M.Map var [delta]
type Environment st var delta  = M.Map st (Valuation var delta)

data Atom var func             = VarA var | ConstA (Rng func) | FuncA func
type UpdateStringFunc var func = [Atom var func]
type UpdateString var rng      = [Either var rng]
type RegisterUpdate var func   = M.Map var (UpdateStringFunc var func)

data EdgeSet st pred func var =
  EdgeSet
  { eForward  :: M.Map st [(pred, RegisterUpdate var func, st)]
  , eBackward :: M.Map st [(pred, RegisterUpdate var func, st)]
  }

data SST st pred func var =
  SST
  { sstS :: S.Set st                               -- ^ State set
  , sstE :: EdgeSet st pred func var               -- ^ Symbolic transition relation
  , sstI :: st                                     -- ^ Initial state
  , sstF :: M.Map st (UpdateString var (Rng func)) -- ^ Final states with final output
  , sstV :: S.Set var                              -- ^ Output variables. The minimal variable is the designated output variable.
  }

-- | Get the designated output variable of an SST.
sstOut :: SST st pred func var -> var
sstOut = S.findMin . sstV

deriving instance (Show var, Show func, Show (Rng func)) => Show (Atom var func)
deriving instance (Show st, Show pred, Show func, Show var, Show (Rng func))
             => Show (EdgeSet st pred func var)
deriving instance (Show st, Show pred, Show func, Show var, Show (Rng func))
             => Show (SST st pred func var)

evalUpdateStringFunc :: (Function func, Rng func ~ [delta]) =>
                        Dom func -> UpdateStringFunc var func -> UpdateString var [delta]
evalUpdateStringFunc x = normalizeUpdateString . map subst
    where
      subst (VarA v)   = Left v
      subst (ConstA y) = Right y
      subst (FuncA f)  = Right $ eval f x

constUpdateStringFunc :: UpdateString var (Rng func) -> UpdateStringFunc var func
constUpdateStringFunc = map subst
    where
      subst (Left v) = VarA v
      subst (Right x) = ConstA x

normalizeUpdateStringFunc :: (Rng func ~ [delta]) => UpdateStringFunc var func -> UpdateStringFunc var func
normalizeUpdateStringFunc = go
    where
      go [] = []
      go (ConstA x:ConstA y:xs) = go (ConstA (x ++ y):xs)
      go (ConstA x:xs) = ConstA x:go xs
      go (VarA v:xs) = VarA v:go xs
      go (FuncA f:xs) = FuncA f:go xs

normalizeRegisterUpdate :: (Rng func ~ [delta]) => RegisterUpdate var func -> RegisterUpdate var func
normalizeRegisterUpdate = M.map normalizeUpdateStringFunc

normalizeUpdateString :: UpdateString var [delta] -> UpdateString var [delta]
normalizeUpdateString = go
    where
      go [] = []
      go (Right x:Right y:xs) = Right (x++y):xs
      go (Left v:xs) = Left v:go xs
      go (Right x:xs) = Right x:go xs

edgesFromList :: (Ord st) => [(st, pred, RegisterUpdate var func, st)] -> EdgeSet st pred func var
edgesFromList xs = EdgeSet { eForward  = M.fromListWith (++) [ (q,  [(p, u, q')]) | (q,p,u,q') <- xs ]
                           , eBackward = M.fromListWith (++) [ (q', [(p, u, q)])  | (q,p,u,q') <- xs ]
                           }

edgesToList :: EdgeSet st pred func var -> [(st, pred, RegisterUpdate var func, st)]
edgesToList es = [ (q,p,u,q') | (q, xs) <- M.toList (eForward es), (p,u,q') <- xs ]

mapEdges :: (Ord st)
         => ((st, pred, RegisterUpdate var func, st) -> (st, pred, RegisterUpdate var func, st))
         -> EdgeSet st pred func var
         -> EdgeSet st pred func var
mapEdges f = edgesFromList . map f . edgesToList

-- | Construct an SST from an edge set and a list of final outputs.
construct :: (Ord st, Ord var, Rng func ~ [delta]) =>
       st                                                   -- ^ Initial state
    -> [(st, pred, [(var, UpdateStringFunc var func)], st)] -- ^ Edge set
    -> [(st, UpdateString var [delta])]                     -- ^ Final outputs
    -> SST st pred func var
construct qin es os =
  SST
  { sstS = S.fromList (qin:concat [ [q, q'] | (q, _, _, q') <- es ])
  , sstE = edgesFromList [ (q, p, ru us, q') | (q, p, us, q') <- es ]
  , sstI = qin
  , sstF = outf [(q, normalizeUpdateString us) | (q, us) <- os]
  , sstV = S.fromList [ v | (_,_,xs,_) <- es, (v,_) <- xs ]
  }
  where
    outf = M.fromListWith (error "Inconsistent output function: Same state has more than one update.")
    ru = normalizeRegisterUpdate
         . M.fromListWith (error "Inconsistent register update: Same variable updated more than once.")

construct' :: (Ord st, Ord var, Rng func ~ [delta]) =>
       st                                        -- ^ Initial state
    -> [(st, pred, RegisterUpdate var func, st)] -- ^ Edge set
    -> [(st, [Either var [delta]])]              -- ^ Final outputs
    -> SST st pred func var
construct' qin es os =
  SST
  { sstS = S.fromList (qin:concat [ [q, q'] | (q, _, _, q') <- es ])
  , sstE = edgesFromList [ (q, p, normalizeRegisterUpdate ru, q') | (q, p, ru, q') <- es ]
  , sstI = qin
  , sstF = outf [(q, normalizeUpdateString us) | (q, us) <- os]
  , sstV = S.fromList [ v | (_,_,ru,_) <- es, v <- M.keys ru ]
  }
  where
    outf = M.fromListWith (error "Inconsistent output function: Same state has more than one update.")

{-- Analysis --}

data AbstractVal rng = Exact rng | Ambiguous deriving (Eq, Ord, Show, Functor)
type AbstractValuation var delta = M.Map var (AbstractVal [delta])
type AbstractEnvironment st var delta = M.Map st (AbstractValuation var delta)

instance Applicative AbstractVal where
  pure = Exact
  (Exact f) <*> (Exact x) = Exact (f x)
  _ <*> _ = Ambiguous

isExact :: AbstractVal a -> Bool
isExact (Exact _) = True
isExact _ = False

lubAbstractVal :: (Eq a) => AbstractVal a -> AbstractVal a -> AbstractVal a
lubAbstractVal (Exact x) (Exact y) = if x == y then Exact x else Ambiguous
lubAbstractVal _ _ = Ambiguous

lubAbstractValuations :: (Ord var, Eq delta) =>
                         [AbstractValuation var delta] -> AbstractValuation var delta
lubAbstractValuations = M.unionsWith lubAbstractVal


liftAbstractValuation :: (Ord var, Function func, Rng func ~ [delta]) =>
                         AbstractValuation var delta
                      -> UpdateStringFunc var func
                      -> Maybe (AbstractVal [delta])
liftAbstractValuation rho = go
  where
    go [] = return (pure [])
    go (VarA v:xs) = liftA2 (++) <$> M.lookup v rho <*> go xs
    go (FuncA f:xs) = case isConst f of
                        Nothing -> Just Ambiguous
                        Just ys  -> liftA (ys++) <$> go xs
    go (ConstA ys:xs) = liftA (ys++) <$> go xs

updateAbstractValuation :: (Ord var, Function func, Rng func ~ [delta]) =>
                           AbstractValuation var delta
                        -> RegisterUpdate var func
                        -> AbstractValuation var delta
updateAbstractValuation rho kappa = M.union (M.mapMaybe (liftAbstractValuation rho) kappa) rho

applyAbstractValuation :: (Ord var, Function func, Rng func ~ [delta]) => 
                          AbstractValuation var delta
                       -> UpdateStringFunc var func
                       -> UpdateStringFunc var func
applyAbstractValuation rho = normalizeUpdateStringFunc . map subst
    where
      subst (VarA v) | Just (Exact ys) <- M.lookup v rho = ConstA ys
                     | otherwise = VarA v
      subst a = a

updateAbstractEnvironment :: (Ord st, Ord var, Eq delta
                             ,Function func, Rng func ~ [delta]) =>
                             SST st pred func var
                          -> [st]
                          -> AbstractEnvironment st var delta
                          -> (AbstractEnvironment st var delta, [st])
updateAbstractEnvironment sst states gamma =
  (M.union updates gamma
  ,S.toList $ S.unions (map succs (M.keys updates)))
  where
    -- Compute the set of successors of a given state
    succs q =
      S.fromList [ q' | Just xs <- [M.lookup q (eForward $ sstE sst)], (_,_,q') <- xs ]

    updates = M.unions $ do
      s <- states
      -- Compute the abstract valuation for the current state by applying the
      -- update function to the abstract valuations of all predecessors and
      -- taking the least upper bound.
      let rho_s' =
            lubAbstractValuations $
              [ maybe M.empty id (M.lookup r gamma) `updateAbstractValuation` kappa
                | (_, kappa, r) <- maybe [] id (M.lookup s (eBackward $ sstE sst)) ]
      -- Get the previous abstract valuation for the current state
      let rho_s = maybe M.empty id (M.lookup s gamma)
      -- Did we learn more information?
      guard (rho_s' /= rho_s)
      return (M.singleton s rho_s')

abstractInterpretation :: (Ord st, Ord var, Eq delta
                          ,Function func, Rng func ~ [delta]) =>
                          SST st pred func var
                       -> AbstractEnvironment st var delta
abstractInterpretation sst = go (S.toList $ sstS sst) M.empty
    where
      go [] gamma = gamma
      go states gamma = let (gamma', states') = updateAbstractEnvironment sst states gamma
                        in go states' gamma'

applyAbstractEnvironment :: (Ord st, Ord var, Function func, Rng func ~ [delta]) =>
                            AbstractEnvironment st var delta
                         -> SST st pred func var
                         -> SST st pred func var
applyAbstractEnvironment gamma sst =
  sst { sstE = mapEdges apply (sstE sst) }
  where
    apply (q, p, kappa, q') =
      let srcRho = maybe M.empty id (M.lookup q gamma)
          exactKeys = M.keys $ M.filter isExact $ maybe M.empty id (M.lookup q' gamma)
          kappa' = M.map (applyAbstractValuation srcRho) $ foldr M.delete kappa exactKeys
      in (q, p, kappa', q')

optimize :: (Eq delta, Ord st, Ord var, Function func, Rng func ~ [delta]) =>
            SST st pred func var
         -> SST st pred func var
optimize sst = let gamma = abstractInterpretation sst in applyAbstractEnvironment gamma sst

enumerateStates :: (Ord k, Ord var) => SST k pred func var -> SST Int pred func var
enumerateStates sst =
    SST
    { sstS = S.fromList $ M.elems states
    , sstE = edgesFromList [ (aux q, p, f, aux q') | (q, p, f, q') <- edgesToList (sstE sst) ]
    , sstI = aux . sstI $ sst
    , sstF = M.fromList [ (aux q, o) | (q, o) <- M.toList (sstF sst) ]
    , sstV = sstV sst
    }
    where
      states = M.fromList (zip (S.toList (sstS sst)) [(0::Int)..])
      aux q = states M.! q

{-- Simulation --}

data Stream a = Chunk a (Stream a) | Done | Fail String
  deriving (Show)

valuate :: (Ord var) => Valuation var delta -> UpdateString var [delta] -> [delta]
valuate _ [] = []
valuate s (Right d:xs) = d ++ valuate s xs
valuate s (Left v:xs) = maybe (error "valuate: Variable not in valuation") id (M.lookup v s)
                        ++ valuate s xs

run :: (Ord t, Ord st, SetLike pred (Dom func),
        Function func, Rng func ~ [delta])
    => SST st pred func t
    -> [Dom func]
    -> Stream [delta]
run sst = go (sstI sst) (M.fromList [ (x, []) | x <- S.toList (sstV sst) ])
    where
      outVar = S.findMin (sstV sst)

      extractOutput s =
        case M.lookup outVar s of
          Nothing -> error "Output variable not in valuation"
          Just x -> (x, M.insert outVar [] s)

      go q s [] =
        case M.lookup q (sstF sst) of
          Nothing -> Fail "End of input reached, but final state is not accepting."
          Just out -> Chunk (valuate s out) Done
      go q s (a:as) = maybe (Fail "No match") id $ do
        ts <- M.lookup q (eForward $ sstE sst)
        (upd, q') <- findTrans a ts
        let (out, s') = extractOutput $ M.map (valuate s . evalUpdateStringFunc a) upd
        return $ Chunk out (go q' s' as)

      findTrans _ [] = Nothing
      findTrans a ((p, upd, q'):ts) =
        if member a p then
            Just (upd, q')
        else
            findTrans a ts
