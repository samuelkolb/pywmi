# Not to be confused with the vtree's in PySDD library.
# This is for ease of use in Python, but eventually you'll want to
# convert the vtrees here to a vtree usable by the PySDD library.
from abc import ABC, abstractmethod

from dataclasses import dataclass
from itertools import product, combinations
from collections import defaultdict
import tempfile
from datetime import datetime

from pysdd.sdd import Vtree as PysddVtree

from pywmi.engines.xsdd.literals import LiteralInfo
from pywmi.engines.xsdd.vtrees.int_tree import IntTreeFactory
from pywmi.engines.xsdd.vtrees.primal import create_interaction_graph_from_literals
from pywmi.smt_math import LinearInequality

_pydot = None


def get_pydot():
    global _pydot
    if _pydot is None:
        import pydot, re

        pydot.id_re_with_port = re.compile("^([^:]*):(.*)$", re.UNICODE)
        _pydot = pydot
    return _pydot


class Vtree(ABC):

    @abstractmethod
    def all_leaves(self):
        pass

    @abstractmethod
    def count(self) -> int:
        pass

    @abstractmethod
    def count_leaves(self) -> int:
        pass

    @abstractmethod
    def all_nodes(self):
        pass

    @abstractmethod
    def depth(self) -> int:
        pass

    @abstractmethod
    def balanced_add(self, vtree, prefer_left):
        pass

    @abstractmethod
    def _to_dot(self, g):
        pass

    @abstractmethod
    def _to_pysdd(self, f, varnums):
        pass

    def to_dot(self):
        dot = get_pydot()
        g = dot.Dot(graph_type="digraph")
        self._to_dot(g)
        return g

    @classmethod
    def create_balanced(cls, varlist: list, prefer_left: bool):
        if len(varlist) == 0:
            return VtreeEmpty()

        root = VtreeVar(varlist[0])
        for var in varlist[1:]:
            root = root.balanced_add(VtreeVar(var), prefer_left)

        # Now replace the order... There's probably a more elegant way?
        for leaf, var in zip(root.all_leaves(), varlist):
            leaf.var = var
        return root

    @classmethod
    def create_rightlinear(cls, varlist):
        if len(varlist) == 0:
            return VtreeEmpty()
        t = VtreeVar(varlist[0])
        for var in varlist[1:]:
            t = VtreeSplit(VtreeVar(var), t)
        return t

    @classmethod
    def create_leftlinear(cls, varlist):
        if len(varlist) == 0:
            return VtreeEmpty()
        t = VtreeVar(varlist[0])
        for var in varlist[1:]:
            t = VtreeSplit(t, VtreeVar(var))
        return t

    def all_vars(self):
        for l in self.all_leaves():
            yield l.var

    def to_pysdd(self, varnums):
        # After skimming the documention of the PySDD library, there doesn't
        # seem to be an easy way to manually 'build' a vtree.
        # However, there is a save/load mechanism, so we'll use that instead.

        # Inline documentation of such files:
        # ids of vtree nodes start at 0
        # ids of variables start at 1
        # vtree nodes appear bottom-up, children before parents
        #
        # file syntax:
        # vtree number-of-nodes-in-vtree
        # L id-of-leaf-vtree-node id-of-variable
        # I id-of-internal-vtree-node id-of-left-child id-of-right-child

        for internal_id, node in enumerate(self.all_nodes()):
            node._internal_id = internal_id

        with tempfile.NamedTemporaryFile(mode="w+") as f:
            f.write("c Generated by PyWMI\n")
            f.write(f"vtree {self.count()}\n")
            self._to_pysdd(f, varnums)
            f.flush()
            vtree = PysddVtree.from_file(f.name)

        return vtree


class VtreeEmpty(Vtree):
    depth = lambda s: 0
    count_leaves = lambda s: 0
    count = lambda s: 0
    all_leaves = lambda s: (yield from [])
    all_nodes = lambda s: (yield from [])
    balanced_add = lambda s, v, pl: s
    _to_dot = lambda s, g: None
    _to_pysdd = lambda s, f, vn: None


@dataclass
class VtreeSplit(Vtree):
    primes: Vtree  # left
    subs: Vtree  # right

    def depth(self):
        return max(self.primes.depth(), self.subs.depth()) + 1

    def count_leaves(self):
        return self.primes.count_leaves() + self.subs.count_leaves()

    def count(self):
        return self.primes.count() + self.subs.count() + 1

    def all_leaves(self):
        yield from self.primes.all_leaves()
        yield from self.subs.all_leaves()

    def all_nodes(self):
        yield from self.primes.all_nodes()
        yield from self.subs.all_nodes()
        yield self

    def balanced_add(self, vtree, prefer_left=False):
        lc = self.primes.count()
        rc = self.subs.count()
        if (lc < rc) or (lc == rc and prefer_left):
            return VtreeSplit(self.primes.balanced_add(vtree, prefer_left), self.subs)
        else:
            return VtreeSplit(self.primes, self.subs.balanced_add(vtree, prefer_left))

    def _to_dot(self, g):
        dot = get_pydot()
        node = dot.Node(str(id(self)), shape="point")
        g.add_node(node)
        primes_node = self.primes._to_dot(g)
        subs_node = self.subs._to_dot(g)
        g.add_edge(dot.Edge(node, primes_node, arrowhead="none"))
        g.add_edge(dot.Edge(node, subs_node, arrowhead="none"))
        return node

    def _to_pysdd(self, f, varnums):
        self.primes._to_pysdd(f, varnums)
        self.subs._to_pysdd(f, varnums)
        f.write(
            f"I {self._internal_id} {self.primes._internal_id} {self.subs._internal_id}\n"
        )


@dataclass
class VtreeVar(Vtree):
    var: str

    depth = lambda s: 0
    count = count_leaves = lambda s: 1
    all_leaves = all_nodes = lambda s: (yield s)

    def balanced_add(self, vtree, prefer_left):
        if prefer_left:
            return VtreeSplit(vtree, self)
        else:
            return VtreeSplit(self, vtree)

    def _to_dot(self, g):
        dot = get_pydot()
        node = dot.Node(str(self.var).replace(":", "="), shape="plain")
        g.add_node(node)
        return node

    def _to_pysdd(self, f, varnums):
        f.write(f"L {self._internal_id} {varnums[self.var]}\n")


def _conversion_tables(literals: LiteralInfo):
    logic2cont = defaultdict(set)
    cont2logic = defaultdict(set)
    for formula, lit in literals.abstractions.items():
        cvars = set(LinearInequality.from_smt(formula).variables)
        logic2cont[lit] = cvars
        for cvar in cvars:
            cont2logic[cvar].add(lit)
    for var, lit in literals.booleans.items():
        if literals.labels and var in literals.labels:
            pos_val, neg_val = literals.labels[var]
            logic2cont[lit] = {s.symbol_name() for s in pos_val.get_free_variables()}
            logic2cont[lit] |= {s.symbol_name() for s in neg_val.get_free_variables()}
            for cvar in logic2cont[lit]:
                cont2logic[cvar].add(lit)
        else:
            logic2cont[lit] = set()
    return logic2cont, cont2logic


def balanced(literals: LiteralInfo):
    return Vtree.create_balanced(list(literals), True)


def rightlinear(literals: LiteralInfo):
    return Vtree.create_rightlinear(list(literals))


def leftlinear(literals: LiteralInfo):
    return Vtree.create_leftlinear(list(literals))


def bami(literals: LiteralInfo) -> Vtree:
    """
    Create a vtree by using a balanced min-fill approach, improving the balance of the integration order in the vtree.
    :param literals: The context to create a vtree for.
    :return: A vtree based on a balanced min-fill ordering.
    """
    logic2cont, cont2logic = _conversion_tables(literals)
    primal = create_interaction_graph_from_literals(
        cont2logic.keys(), logic2cont.values(), True, False
    )
    int_factory = IntTreeFactory(primal)

    primal.compute_fills()
    while primal.nb_fills() > 0:
        minfills = primal.get_minfills()
        minfills = int_factory.get_least_depth_increase(minfills)  # balanced
        minfills = primal.get_lowest_future_minfill(minfills)  # balanced
        selected_var = minfills[0]
        int_factory.add_node(selected_var)
        primal.remove_and_process_node(selected_var)
    return int_factory.get_int_tree().create_vtree(set(logic2cont.keys()), logic2cont)
