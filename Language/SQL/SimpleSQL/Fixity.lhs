
This is the module which deals with fixing up the scalar expression
trees for the operator precedence and associativity (aka 'fixity').

It currently uses haskell-src-exts as a hack, the algorithm from there
should be ported to work on these trees natively. Maybe it could be
made generic to use in places other than the scalar expr parser?

> {-# LANGUAGE TupleSections #-}
> module Language.SQL.SimpleSQL.Fixity
>        (fixFixities
>        ,Fixity(..)
>        ,Assoc(..)
>        ,infixl_
>        ,infixr_
>        ,infix_
>        ) where

> import qualified Language.Haskell.Exts.Syntax as HSE
> import qualified Language.Haskell.Exts.Fixity as HSE
> import Control.Monad.Identity
> import Control.Applicative
> import Data.Maybe

> import Language.SQL.SimpleSQL.Syntax

> data Fixity = Fixity String --name of op
>                      Assoc
>               deriving (Eq,Show)

> data Assoc = AssocLeft | AssocRight | AssocNone
>              deriving (Eq,Show)

> infixl_ :: [String] -> [Fixity]
> infixl_ = map (`Fixity` AssocLeft)

> infixr_ :: [String] -> [Fixity]
> infixr_ = map (`Fixity` AssocRight)

> infix_ :: [String] -> [Fixity]
> infix_ = map (`Fixity` AssocNone)

> toHSEFixity :: [[Fixity]] -> [HSE.Fixity]
> toHSEFixity fs =
>     let fs' = zip [0..] $ reverse fs
>     in concatMap f fs'
>   where
>     f :: (Int, [Fixity]) -> [HSE.Fixity]
>     f (n,fs') = flip concatMap fs' $ \(Fixity nm assoc) ->
>                 case assoc of
>                     AssocLeft -> HSE.infixl_ n [nm]
>                     AssocRight -> HSE.infixr_ n [nm]
>                     AssocNone -> HSE.infix_ n [nm]

fix the fixities in the given scalar expr. All the expressions to be
fixed should be left associative and equal precedence to be fixed
correctly. It doesn't descend into query expressions in subqueries and
the scalar expressions they contain.

TODO: get it to work on prefix and postfix unary operators also maybe
it should work on some of the other syntax (such as in).

> fixFixities :: [[Fixity]] -> ScalarExpr -> ScalarExpr
> fixFixities fs se =
>   runIdentity $ toSql <$> HSE.applyFixities (toHSEFixity fs) (toHaskell se)

Now have to convert all our scalar exprs to haskell and back again.
Have to come up with a recipe for each ctor. Only continue if you have
a strong stomach. Probably would have been less effort to just write
the fixity code.

> toHaskell :: ScalarExpr -> HSE.Exp
> toHaskell e = case e of
>     BinOp e0 op e1 -> HSE.InfixApp
>                       (toHaskell e0)
>                       (HSE.QVarOp $ sym $ name op)
>                       (toHaskell e1)
>     Iden {} -> str ('v':show e)
>     StringLit {} -> str ('v':show e)
>     NumLit {} -> str ('v':show e)
>     App n es -> HSE.App (var ('f':name n)) $ ltoh es
>     Parens e0 -> HSE.Paren $ toHaskell e0
>     IntervalLit {} -> str ('v':show e)
>     Star -> str ('v':show e)
>     AggregateApp nm d es od ->
>         HSE.App (var ('a':name nm))
>         $ HSE.List [str $ show (d,orderInf od)
>                    ,HSE.List $ map toHaskell es
>                    ,HSE.List $ orderExps od]
>     WindowApp nm es pb od r ->
>         HSE.App (var ('w':name nm))
>         $ HSE.List [str $ show (orderInf od, r)
>                    ,HSE.List $ map toHaskell es
>                    ,HSE.List $ map toHaskell pb
>                    ,HSE.List $ orderExps od]
>     PrefixOp nm e0 ->
>         HSE.App (HSE.Var $ sym $ name nm) (toHaskell e0)
>     PostfixOp nm e0 ->
>         HSE.App (HSE.Var $ sym ('p':name nm)) (toHaskell e0)
>     SpecialOp nm es ->
>         HSE.App (var ('s':name nm)) $ HSE.List $ map toHaskell es
>     -- map the two maybes to lists with either 0 or 1 element
>     Case v ts el -> HSE.App (var "$case")
>                     (HSE.List [ltoh $ maybeToList v
>                               ,HSE.List $ map (ltoh . (\(a,b) -> b:a)) ts
>                               ,ltoh $ maybeToList el])
>     Cast e0 tn -> HSE.App (str ('c':show tn)) $ toHaskell e0
>     TypedLit {} -> str ('v':show e)
>     SubQueryExpr {} -> str ('v': show e)
>     In b e0 (InList l) ->
>         HSE.App (str ('i':show b))
>         $ HSE.List [toHaskell e0, HSE.List $ map toHaskell l]
>     In b e0 i -> HSE.App (str ('j':show (b,i))) $ toHaskell e0
>   where
>     ltoh = HSE.List . map toHaskell
>     str = HSE.Lit . HSE.String
>     var = HSE.Var . HSE.UnQual . HSE.Ident
>     sym = HSE.UnQual . HSE.Symbol
>     name n = case n of
>        QName q -> '"' : q
>        Name m -> m
>     orderExps = map (toHaskell . (\(OrderField a _ _) -> a))
>     orderInf = map (\(OrderField _ b c) -> (b,c))




> toSql :: HSE.Exp -> ScalarExpr
> toSql e = case e of


>     HSE.InfixApp e0 (HSE.QVarOp (HSE.UnQual (HSE.Symbol n))) e1 ->
>         BinOp (toSql e0) (unname n) (toSql e1)
>     HSE.Lit (HSE.String ('v':l)) -> read l
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Ident ('f':i))))
>             (HSE.List es) -> App (unname i) $ map toSql es
>     HSE.Paren e0 -> Parens $ toSql e0
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Ident ('a':i))))
>             (HSE.List [HSE.Lit (HSE.String vs)
>                       ,HSE.List es
>                       ,HSE.List od]) ->
>         let (d,oinf) = read vs
>         in AggregateApp (unname i) d (map toSql es)
>                         $ sord oinf od
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Ident ('w':i))))
>             (HSE.List [HSE.Lit (HSE.String vs)
>                       ,HSE.List es
>                       ,HSE.List pb
>                       ,HSE.List od]) ->
>         let (oinf,r) = read vs
>         in WindowApp (unname i) (map toSql es) (map toSql pb)
>                        (sord oinf od) r
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Symbol ('p':nm)))) e0 ->
>         PostfixOp (unname nm) $ toSql e0
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Symbol nm))) e0 ->
>         PrefixOp (unname nm) $ toSql e0
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Ident ('s':nm)))) (HSE.List es) ->
>         SpecialOp (unname nm) $ map toSql es
>     HSE.App (HSE.Var (HSE.UnQual (HSE.Ident "$case")))
>             (HSE.List [v,ts,el]) ->
>         Case (ltom v) (whens ts) (ltom el)
>     HSE.App (HSE.Lit (HSE.String ('c':nm))) e0 ->
>         Cast (toSql e0) (read nm)
>     HSE.App (HSE.Lit (HSE.String ('i':nm)))
>             (HSE.List [e0, HSE.List es]) ->
>         In (read nm) (toSql e0) (InList $ map toSql es)
>     HSE.App (HSE.Lit (HSE.String ('j':nm))) e0 ->
>         let (b,sq) = read nm
>         in In b (toSql e0) sq
>     _ -> err e
>   where
>     sord = zipWith (\(i0,i1) ce -> OrderField (toSql ce) i0 i1)
>     ltom (HSE.List []) = Nothing
>     ltom (HSE.List [ex]) = Just $ toSql ex
>     ltom ex = err ex
>     whens (HSE.List l) = map (\(HSE.List (t:ws)) -> (map toSql ws, toSql t)) l
>     whens ex = err ex
>     err :: Show a => a -> e
>     err a = error $ "simple-sql-parser: internal fixity error " ++ show a
>     unname ('"':nm) = QName nm
>     unname n = Name n
