{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE QuasiQuotes #-}
module KMC.Kleenex.Lang where

import           Control.Monad.State
import qualified Data.Map as M
import qualified Data.Set as S
import           Data.Word (Word8)
import           Data.ByteString (unpack, ByteString, empty)
import           Data.Char (chr, ord)
import           Data.Maybe (fromJust, fromMaybe)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8)

import           KMC.Coding (codeFixedWidthEnumSized, decodeEnum)
import           KMC.Expression
import           KMC.Kleenex.Action
import qualified KMC.Kleenex.Parser as H
import           KMC.OutputTerm (Const(..), InList(..), Ident(..), (:+:)(..), NullFun(..))
import           KMC.RangeSet (singleton, complement, rangeSet, union, RangeSet, size)
import           KMC.Syntax.External (Regex (..), unparse)
import           KMC.Theories (top, indexOf)

-- for test
import KMC.Util.Heredoc
import Debug.Trace

toChar :: (Enum a, Bounded a) => [a] -> Char
toChar = chr . decodeEnum

{-- Intermediate internal data type for the mu-terms.  These use de Bruijn-indices. --}
data Nat = Z | S Nat      deriving (Eq, Ord, Show)
data SimpleMu = SMVar Nat
              | SMLoop SimpleMu
              | SMAlt SimpleMu SimpleMu
              | SMSeq SimpleMu SimpleMu
              | SMWrite ByteString
              | SMRegex Regex
              | SMIgnore SimpleMu
              | SMAction KleenexAction SimpleMu
              | SMAccept
  deriving (Eq, Ord, Show)

nat2int :: Nat -> Int
nat2int Z = 0
nat2int (S n) = 1 + nat2int n

-- | Mu-terms created from Kleenex programs either output the identity on
-- the input character, injected into a list, or the output a constant list
-- of characters.
type KleenexOutTerm = (InList (Ident Word8)) :+: (Const Word8 [Word8])

type KleenexMu a = Mu (RangeSet Word8) KleenexOutTerm a

-- | The term that copies the input char to output.
copyInput :: KleenexOutTerm
copyInput = Inl (InList Ident)

-- | The term that outputs a fixed string (list of Word8).
out :: [Word8] -> KleenexOutTerm
out = Inr . Const

-- | The term that throws away the input char.
skip :: KleenexOutTerm
skip = out [] --Inr NullFun

-- | Get the index of an element in a list, or Nothing.
pos :: (Eq a) => a -> [a] -> Maybe Nat
pos _ []                 = Nothing
pos x (e:_)  | x == e    = return Z
pos x (_:es) | otherwise = S `fmap` (pos x es)

-- | Get the nth element on the stack, or Nothing.
getStack :: Nat -> [a] -> Maybe a
getStack Z     (e : _)  = Just e
getStack (S n) (_ : es) = getStack n es
getStack _ _            = Nothing

-- | Converts a Kleenex AST which consists of a set of terms bound to variables
-- to one simplified mu term, with the terms inlined appropriately.
-- The given identifier is treated as the top-level bound variable,
-- i.e., it becomes the first mu.
kleenexToSimpleMu :: H.Identifier -> H.Kleenex -> SimpleMu
kleenexToSimpleMu initVar (H.Kleenex _ ass) = SMLoop $ evalState (go [initVar] (getVar initVar)) 0
    where
      getVar :: H.Identifier -> H.KleenexTerm
      getVar var = case M.lookup var mp of
                      Just term -> term
                      Nothing   -> error $ "Undefined term: " ++ show var
      mp :: M.Map H.Identifier H.KleenexTerm
      mp = M.fromList (map (\(H.HA (k, v)) -> (k, v)) ass)

      nextIdent :: State Int H.Identifier
      nextIdent = do i <- get
                     put (i+1)
                     return $ H.Identifier $ "|_kleenex_to_simple_mu_ident_" ++ show i

      go :: [H.Identifier] -> H.KleenexTerm -> State Int SimpleMu
      go _    (H.Constant n) = return $ SMWrite n
      go vars (H.Var name) =
          case name `pos` vars of
            Nothing ->
                case M.lookup name mp of
                  Nothing -> error $ "Name not found: " ++ show name
                  Just t  -> fmap SMLoop $ go (name : vars) t
            Just p  -> return $ SMVar p
      go vars (H.Sum l r)     = do gol <- go vars l
                                   gor <- go vars r
                                   return $ SMAlt gol gor
      go vars (H.Seq l r)     = do gol <- go vars l
                                   gor <- go vars r
                                   return $ SMSeq gol gor
      go vars (H.Star e)      = do i <- nextIdent
                                   fmap SMLoop $ go (i : vars) $ H.Sum (H.Seq e $ H.Var i) H.One
      go vars (H.Plus e)      = go vars $ H.Seq e $ H.Star e
      go vars (H.Question e)  = do goe <- go vars e
                                   return $ SMAlt goe SMAccept
      go vars (H.Action a e)   = fmap (SMAction a) $ go vars e
      go vars (H.Range l r e) = do goe <- go vars e
                                   let m = fromMaybe 0 l
                                   rest <- case r of
                                              Nothing -> fmap (: []) $ go vars $ H.Star e
                                              Just n  -> if n < m then error $ "Invalid range: " ++ show m ++ "-" ++ show n
                                                                  else return $ replicate (n-m) (SMAlt goe SMAccept)
                                   return $ foldl1 SMSeq $ replicate m goe ++ rest
      go _    H.One           = return $ SMAccept
      go vars (H.Ignore e)    = fmap SMIgnore $ go vars e
      go _    (H.RE re)       = return $ SMRegex re


-- | Find the locations of subterms that are suppressed.
-- It infers the "most general location" like so:
--      (a) E = ~l ~r     --> E' = ~(l r)
--      (b) E = ~l | ~r   --> E' = ~(l | r)
--      (c) E = (~e)*     --> E' = ~(e*)
findSuppressedSubterms :: SimpleMu -> Marked
findSuppressedSubterms = go [] S.empty
    where
      addIfBoth cp marks =
          if (L:cp) `S.member` marks && (R:cp) `S.member` marks
          then S.insert cp marks
          else marks
      go cp marked sm =
          case sm of
            SMLoop e   ->
                let marks = go (L:cp) marked e
                in if (L:cp) `S.member` marks
                   then S.insert cp marks
                   else marks
            SMAlt l r  ->
                addIfBoth cp $ (go (L:cp) marked l) `S.union` (go (R:cp) marked r)
            SMSeq l r  ->
                addIfBoth cp $ (go (L:cp) marked l) `S.union` (go (R:cp) marked r)
            SMIgnore e -> S.insert cp marked
            SMAccept   -> marked
            SMVar _    -> marked
            SMWrite _  -> marked
            SMRegex _  -> marked


-- | A simple mu term is converted to a "real" mu term by converting the
-- de Bruijn-indexed variables to Haskell variables, and encoding the mu
-- abstractions as Haskell functions.  This function therefore converts
-- a de Bruijn representation to a HOAS representation.  All embedded
-- regular expressions are also represented as mu-terms.
simpleMuToMuTerm' :: [KleenexMu a] -> Bool -> SimpleMu -> KleenexMu a
simpleMuToMuTerm' st ign sm =
    case sm of
      SMVar n      -> maybe (error "stack exceeded") id $ getStack n st
      SMLoop sm'   -> Loop $ \x -> simpleMuToMuTerm' ((Var x) : st) ign sm'
      SMAlt l r    -> Alt (simpleMuToMuTerm' st ign l)
                          (simpleMuToMuTerm' st ign r)
      SMSeq l r    -> Seq (simpleMuToMuTerm' st ign l)
                          (simpleMuToMuTerm' st ign r)
      SMWrite s    -> if ign
                      then Accept
                      else W (unpack s) Accept
      SMRegex re   -> if ign
                      then regexToMuTerm skip re
                      else regexToMuTerm copyInput re
      SMIgnore sm' -> simpleMuToMuTerm' st True sm'
      SMAction a e -> Accept
      SMAccept -> Accept

simpleMuToMuTerm :: SimpleMu -> KleenexMu a
simpleMuToMuTerm sm = simpleMuToMuTerm' [] False sm

-- | Convert a Kleenex program to a list of mu-term that encodes the string transformations
-- expressed in Kleenex.
kleenexToActionMuTerm :: H.Kleenex -> [KleenexActionMu a]
kleenexToActionMuTerm k@(H.Kleenex is terms) = map (\i -> simpleMuToActionMuTerm [] False $ kleenexToSimpleMu i k) is

kleenexToMuTerm :: H.Kleenex -> [(KleenexMu a, Marked)]
kleenexToMuTerm k@(H.Kleenex is h) = map f is
    where
      f i = let sm = kleenexToSimpleMu i k
            in (simpleMuToMuTerm sm, findSuppressedSubterms sm)

encodeChar :: Char -> [Word8]
encodeChar = unpack . encodeUtf8 . T.singleton

-- | Translates a regular expression into a mu-term that performs the given
-- action on the matched symbols: It either copies any matched symbols or
-- ignores them.
regexToMuTerm :: KleenexOutTerm -> Regex -> KleenexMu a
regexToMuTerm o re =
    case re of
       One        -> Accept
       Dot        -> RW top o Accept
       Chr a      -> foldr1 Seq $ map (\c -> RW (singleton c) o Accept) (encodeChar a)
       Group _ e  -> regexToMuTerm o e
       Concat l r -> (regexToMuTerm o l) `Seq` (regexToMuTerm o r)
       Branch l r -> (regexToMuTerm o l) `Alt` (regexToMuTerm o r)
       Class b rs ->
           let rs' = (if b then id else complement) $
                     rangeSet [ (toEnum (ord lo), toEnum (ord hi)) |
                                (lo, hi) <- rs ]
           in RW rs' o Accept
       Star e     -> Loop $ \x -> ((regexToMuTerm o e) `Seq` (Var x)) `Alt` Accept
       LazyStar e -> Loop $ \x -> Accept `Alt`
                                    ((regexToMuTerm o e) `Seq` (Var x))
       Plus e     -> (regexToMuTerm o e) `Seq`
                                 (regexToMuTerm o (Star e))
       LazyPlus e -> (regexToMuTerm o e) `Seq`
                                 (regexToMuTerm o (LazyStar e))
       Question e -> (regexToMuTerm o e) `Alt` Accept
       LazyQuestion e -> Accept `Alt` (regexToMuTerm o e)
       Suppress e -> regexToMuTerm (out []) e
       Range e n m ->
           let start expr = case m of
                             Nothing -> expr `Seq` (regexToMuTerm o (Star e))
                             Just n' -> expr `Seq` (foldr Seq Accept
                                                    (replicate (n' - n)
                                                    (regexToMuTerm o (Question e))))
           in start (foldr Seq Accept
                     (replicate n (regexToMuTerm o e)))
       NamedSet _ _    -> error "Named sets not yet supported"
       LazyRange _ _ _ -> error "Lazy ranges not yet supported"


testKleenex :: String -> Either String [(KleenexMu a, Marked)]
testKleenex s = either Left (Right . kleenexToMuTerm) (H.parseKleenex s)

--- Kleenex with actions translation


simpleMuToActionMuTerm :: [KleenexActionMu a] -> Bool -> SimpleMu -> KleenexActionMu a
simpleMuToActionMuTerm st ign sm =
    case sm of
      SMVar n      -> maybe (error "stack exceeded") id $ getStack n st
      SMLoop sm'   -> (Loop $ \x -> simpleMuToActionMuTerm ((Var x) : st) ign sm')
      SMAlt l r    -> (simpleMuToActionMuTerm st ign l) `Alt` (simpleMuToActionMuTerm st ign r)
      SMSeq l r    -> (simpleMuToActionMuTerm st ign l) `Seq` (simpleMuToActionMuTerm st ign r)
      SMWrite bs   -> if ign
                      then Accept
                      else W (unpack bs) Accept
      SMRegex re   -> regexToActionMuTerm ign re
      SMIgnore sm' -> simpleMuToActionMuTerm st True sm'
      SMAction a e -> Action a $ simpleMuToActionMuTerm st ign e
      SMAccept     -> Accept

regexToActionMuTerm  :: Bool -> Regex -> KleenexActionMu a
regexToActionMuTerm ign re =
    case re of
        One          -> Accept
        Dot          -> RW top (o top) Accept
        Chr a        -> if ign then Accept else W (encodeChar a) Accept
        Group _ e    -> regexToActionMuTerm ign e
        Concat e1 e2 -> Seq (regexToActionMuTerm ign e1) (regexToActionMuTerm ign e2)
        Branch e1 e2 -> Alt (regexToActionMuTerm ign e1) (regexToActionMuTerm ign e2)
        (Class b rs)   ->  let rs' = (if b then id else complement)
                                     $ rangeSet [ (toEnum (ord lo), toEnum (ord hi)) | (lo, hi) <- rs ]
                               rs'' = rangeSet [ (toEnum 0, toEnum $ size rs' - 1) ]
                           in  RW rs'' (o rs') Accept
        (Star e)       -> Loop $ \x -> Alt (Seq (regexToActionMuTerm ign e) (Var x)) Accept
        (LazyStar e)   -> Loop $ \x -> Alt Accept (Seq (regexToActionMuTerm ign e) (Var x))
        (Plus e)       -> Seq (regexToActionMuTerm ign e) (regexToActionMuTerm ign (Star e))
        (LazyPlus e)   -> Seq (regexToActionMuTerm ign e) (regexToActionMuTerm ign (LazyStar e))
        (Question e)   -> Alt (regexToActionMuTerm ign e) Accept
        (LazyQuestion e)   -> Alt (regexToActionMuTerm ign e) Accept
        (Suppress e)   -> regexToActionMuTerm True e
        (Range e n m)  -> case m of
                           Nothing -> Seq (repeatRegex' ign n e) (regexToActionMuTerm ign (Star e))
                           Just m' -> if n == m' then repeatRegex' ign n e
                                      else Seq (repeatRegex' ign n e) (repeatRegex' ign m' (Question e))
        (NamedSet _ _) -> error "Named sets not yet supported"
        (LazyRange _ _ _) -> error "Lazy ranges not yet supported"
    where
        o = if ign then nop else parseBitsAction


repeatRegex' :: Bool -> Int -> Regex -> KleenexActionMu a
repeatRegex' ign n re = foldr Seq Accept (replicate n (regexToActionMuTerm ign re))


testSimple :: String -> Either String [(SimpleMu, Marked)]
testSimple s = either Left (Right . g) (H.parseKleenex s)
    where
      g k@(H.Kleenex is _) = map (f k) is
      f h i = let sm = kleenexToSimpleMu i h
              in (sm, findSuppressedSubterms sm)

-- mu2 :: SimpleMu -- (KleenexMu a, Marked)
-- mu2 = either (error "woot") head  $ testSimple $ --  testKleenex $
--       [strQ|x
-- x := a | ~b
-- a := <a>
-- b := ~<b>
-- |]
-- mu1 :: (KleenexMu a, Marked)
-- mu1 = either (error "woot") head  $ testKleenex $
--       [strQ|x
-- x := a | ~b
-- a := <a>
-- b := ~<b>
-- |]

-- s1 = [strQ|x
-- x := ((~a b) | (~c ~d))
-- a := /a/
-- b := /b/
-- c := /c/
-- d := /d/
-- |]
