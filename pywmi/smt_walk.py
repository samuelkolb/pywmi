from abc import ABC

import pysmt.shortcuts as smt
from pysmt.operators import POW, IMPLIES


class SmtWalker(object):
    def walk_and(self, args):
        raise NotImplementedError()

    def walk_or(self, args):
        raise NotImplementedError()

    def walk_plus(self, args):
        raise NotImplementedError()

    def walk_minus(self, left, right):
        raise NotImplementedError()

    def walk_times(self, args):
        raise NotImplementedError()

    def walk_not(self, argument):
        raise NotImplementedError()

    def walk_ite(self, if_arg, then_arg, else_arg):
        raise NotImplementedError()

    def walk_pow(self, base, exponent):
        raise NotImplementedError()

    def walk_lte(self, left, right):
        raise NotImplementedError()

    def walk_lt(self, left, right):
        raise NotImplementedError()

    def walk_equals(self, left, right):
        raise NotImplementedError()

    def walk_symbol(self, name, v_type):
        raise NotImplementedError()

    def walk_constant(self, value, v_type):
        raise NotImplementedError()

    def walk_implies(self, left, right):
        return self.walk_smt(smt.Or(smt.Not(left), right))

    def walk_smt_multiple(self, formulas):
        return [self.walk_smt(f) for f in formulas]

    def walk_smt(self, formula):
        """
        Walks the given SMT formula (recursively visits the elements in the SMT formula-DAG)
        :type formula: pysmt.fnode.FNode
        """
        if formula.is_and():
            return self.walk_and(formula.args())
        if formula.is_or():
            return self.walk_or(formula.args())
        if formula.node_type() == IMPLIES:
            return self.walk_implies(formula.arg(0), formula.arg(1))
        if formula.is_not():
            return self.walk_not(formula.arg(0))
        if formula.is_times():
            return self.walk_times(formula.args())
        if formula.is_plus():
            return self.walk_plus(formula.args())
        if formula.is_minus():
            return self.walk_minus(formula.arg(0), formula.arg(1))
        if formula.is_ite():
            return self.walk_ite(formula.arg(0), formula.arg(1), formula.arg(2))
        if formula.node_type() == POW:
            return self.walk_pow(formula.arg(0), formula.arg(1))
        if formula.is_le():
            return self.walk_lte(formula.arg(0), formula.arg(1))
        if formula.is_lt():
            return self.walk_lt(formula.arg(0), formula.arg(1))
        if formula.is_equals():
            return self.walk_equals(formula.arg(0), formula.arg(1))
        if formula.is_symbol():
            return self.walk_symbol(formula.symbol_name(), formula.symbol_type())
        if formula.is_constant():
            return self.walk_constant(formula.constant_value(), formula.constant_type())
        if formula.is_iff():
            return self.walk_and([smt.Implies(formula.arg(0), formula.arg(1)),
                                  smt.Implies(formula.arg(1), formula.arg(0))])
        raise RuntimeError("Cannot walk {} (of type {})".format(formula, formula.node_type()))


class CachedSmtWalker(SmtWalker, ABC):
    def __init__(self,cache_key=None):
        self._cache = dict()
        self.cache_key = cache_key or (lambda f: f)

    def walk_smt(self, formula):
        key = self.cache_key(formula)
        if key in self._cache:
            return self._cache[key]

        result = super().walk_smt(formula)
        self._cache[key] = result
        return result


class SmtIdentityWalker(SmtWalker):
    def walk_and(self, args):
        return smt.And(*self.walk_smt_multiple(args))

    def walk_or(self, args):
        return smt.Or(*self.walk_smt_multiple(args))

    def walk_plus(self, args):
        return smt.Plus(*self.walk_smt_multiple(args))

    def walk_minus(self, left, right):
        return self.walk_smt(left) - self.walk_smt(right)

    def walk_times(self, args):
        return smt.Times(*self.walk_smt_multiple(args))

    def walk_not(self, argument):
        return smt.Not(self.walk_smt(argument))

    def walk_ite(self, if_arg, then_arg, else_arg):
        return smt.Ite(self.walk_smt(if_arg), self.walk_smt(then_arg), self.walk_smt(else_arg))

    def walk_pow(self, base, exponent):
        return smt.Pow(self.walk_smt(base), self.walk_smt(exponent))

    def walk_lte(self, left, right):
        return self.walk_smt(left) <= self.walk_smt(right)

    def walk_lt(self, left, right):
        return self.walk_smt(left) < self.walk_smt(right)

    def walk_equals(self, left, right):
        return smt.Equals(self.walk_smt(left), self.walk_smt(right))

    def walk_symbol(self, name, v_type):
        return smt.Symbol(name, v_type)

    def walk_constant(self, value, v_type):
        if v_type == smt.BOOL:
            return smt.Bool(value)
        elif v_type == smt.REAL:
            return smt.Real(value)
        else:
            return ValueError("Unknown type {}".format(v_type))
