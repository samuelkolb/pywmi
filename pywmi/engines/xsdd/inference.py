from collections import defaultdict
from functools import reduce
from typing import Dict, List, Tuple, Set, Union, Any

from pysmt.fnode import FNode

from pywmi.engines.algebraic_backend import StringAlgebra, XaddAlgebra
from pywmi.smt_print import pretty_print
from .smt_to_sdd import recover_formula

try:
    from pysdd.sdd import SddManager, SddNode
except ImportError:
    SddManager, SddNode = None, None

from pysmt.typing import REAL

from pywmi.engines.integration_backend import IntegrationBackend
from pywmi.smt_math import Polynomial, BoundsWalker, LinearInequality
from pywmi.smt_math import PolynomialAlgebra
from .smt_to_sdd import convert_formula, convert_function
from pywmi import Domain, SmtWalker
from pywmi.engine import Engine
from .semiring import amc, Semiring, SddWalker, walk

import pysmt.shortcuts as smt


class WMISemiring(Semiring):
    def __init__(self, abstractions: Dict, var_to_lit: Dict):
        self.reverse_abstractions = {v: k for k, v in abstractions.items()}
        self.lit_to_var = {v: k for k, v in var_to_lit.items()}

    def times_neutral(self):
        return [smt.TRUE(), set()]

    def plus_neutral(self):
        return []

    def times(self, a, b, index=None):
        result = []
        for f1, v1 in a:
            for f2, v2 in b:
                result.append((f1 & f2, v1 | v2))
        return result

    def plus(self, a, b, index=None):
        return a + b

    def negate(self, a):
        raise NotImplementedError()

    def weight(self, a):
        if abs(a) in self.lit_to_var:
            return [(smt.TRUE(), {self.lit_to_var[abs(a)]})]
        else:
            f = self.reverse_abstractions[abs(a)]
            if a < 0:
                f = ~f
            return [(f, set())]

    def positive_weight(self, a):
        raise NotImplementedError()


class ContinuousProvenanceSemiring(Semiring):
    def __init__(self, abstractions: Dict, var_to_lit: Dict):
        self.reverse_abstractions = {v: k for k, v in abstractions.items()}
        self.lit_to_var = {v: k for k, v in var_to_lit.items()}
        self.index_to_conprov = {}

    def times_neutral(self):
        return (set(), set())

    def plus_neutral(self):
        return (set(), set())

    def plus(self, a, b, index=None):
        assert index
        variables = a[0] | b[0]
        common_variables_children = a[0] & b[0]
        result = (variables, common_variables_children)
        self.index_to_conprov[index] = result
        return result

    def times(self, a, b, index=None):
        assert index
        variables = a[0] | b[0]
        common_variables_children = a[0] & b[0]
        result = (variables, common_variables_children)
        self.index_to_conprov[index] = result
        return result

    def negate(self, a):
        raise NotImplementedError()

    def weight(self, a):
        if abs(a) in self.lit_to_var:
            variables = {self.lit_to_var[abs(a)]}
            self.index_to_conprov[a] = variables
            return (variables, variables)
        else:
            return (set(), set())

    def positive_weight(self, a):
        raise NotImplementedError()


class ParentAnalysis(SddWalker):
    def __init__(self, abstractions: Dict, var_to_lit: Dict):
        self.reverse_abstractions = {v: k for k, v in abstractions.items()}
        self.lit_to_var = {v: k for k, v in var_to_lit.items()}
        self.parents = defaultdict(lambda: [])

    def walk_true(self, node):
        return node.id

    def walk_false(self, node):
        return node.id

    def walk_and(self, prime_result, sub_result, prime, sub):
        node_id = (prime.id, sub.id)
        if prime_result:
            self.parents[prime_result].append(node_id)
        if sub_result:
            self.parents[sub_result].append(node_id)
        return node_id

    def walk_or(self, child_results, node):
        for result in child_results:
            if result:
                self.parents[result].append(node.id)
        return node.id

    def walk_literal(self, a, node):
        return node.id

    @staticmethod
    def get_parents(abstractions: Dict, var_to_lit: Dict, sdd: SddNode) -> Dict:
        analysis = ParentAnalysis(abstractions, var_to_lit)
        walk(analysis, sdd)
        return dict(analysis.parents)

    @staticmethod
    def get_children(abstractions: Dict, var_to_lit: Dict, sdd: SddNode) -> Dict:
        parent_dict = ParentAnalysis.get_parents(abstractions, var_to_lit, sdd)
        children = defaultdict(lambda: [])
        for child, parents in parent_dict.items():
            for parent in parents:
                children[parent].append(child)
        return dict(children)


class VariableTagAnalysis(SddWalker):
    def __init__(self, literal_to_groups):
        self.literal_to_groups = literal_to_groups
        self.node_to_groups = dict()

    def walk_true(self, node):
        print(node.id, node)
        groups = set()
        self.node_to_groups[node.id] = groups
        return groups

    def walk_false(self, node):
        print(node.id, node)
        groups = set()
        self.node_to_groups[node.id] = groups
        return groups

    def walk_and(self, prime_result, sub_result, prime_node, sub_node):
        print((prime_node.id, sub_node.id), prime_node, sub_node)
        groups = prime_result | sub_result
        self.node_to_groups[(prime_node.id, sub_node.id)] = groups
        return groups

    def walk_or(self, child_results, node):
        print(node.id, node)
        groups = reduce(lambda x, y: x | y, child_results, set())
        self.node_to_groups[node.id] = groups
        return groups

    def walk_literal(self, l, node):
        print(node.id, node)
        groups = set(self.literal_to_groups.get(abs(l), []))
        self.node_to_groups[node.id] = groups
        return groups


class IntTagSemiring(Semiring):
    def __init__(self, abstractions: Dict, var_to_lit: Dict, index_to_conprov: Dict):
        self.reverse_abstractions = {v: k for k, v in abstractions.items()}
        self.lit_to_var = {v: k for k, v in var_to_lit.items()}
        self.int_tags = {}

    def negate(self, a):
        raise NotImplementedError()

    def weight(self, a):
        index = a
        if abs(a) in self.lit_to_var:
            return (set(), set())
        else:
            f = self.reverse_abstractions[abs(a)]
            variables = f.variables()  # TODO look up correct method
            return (variables, variables)

    def positive_weight(self, a):
        raise NotImplementedError()


class WMISemiringPint(WMISemiring):
    def __init__(self, abstractions: Dict, var_to_lit: Dict, int_tags: Dict):
        WMISemiring.__init__(abstractions, var_to_lit)
        self.int_tags = int_tags


class FactorizedWMIWalker(SddWalker):
    def __init__(self, domain, abstractions, var_to_lit, groups, dependency, integration_tags):
        # type: (Domain, Dict, Dict, Dict[int, Tuple[Set[str], Polynomial]], Dict, Dict) -> None
        self.domain = domain
        self.reverse_abstractions = {v: k for k, v in abstractions.items()}
        self.lit_to_var = {v: k for k, v in var_to_lit.items()}
        self.groups = groups
        self.dependency = dependency
        self.integration_tags = integration_tags
        self.algebra = XaddAlgebra()

    def walk_true(self, node):
        return node.id, {frozenset(): self.algebra.one()}, set()

    def walk_false(self, node):
        return node.id, {frozenset(): self.algebra.zero()}, set()

    def get_requested_tags(self, parent_id, child_id):
        return frozenset(self.dependency[parent_id][child_id]) if parent_id in self.dependency else frozenset()

    def walk_and(self, prime_result, sub_result, prime_node, sub_node):
        key = (prime_node.id, sub_node.id)
        print("+", "AND", key, prime_result, sub_result)
        prime_id, prime_result, prime_bool_vars = prime_result
        sub_id, sub_result, sub_bool_vars = sub_result
        prime_tags = self.get_requested_tags(key, prime_id)
        sub_tags = self.get_requested_tags(key, sub_id)
        expression = self.algebra.times(prime_result[prime_tags], sub_result[sub_tags])
        bool_vars = prime_bool_vars | sub_bool_vars
        own_tags = self.integration_tags.get(key, {frozenset()})
        expr_dict = self.integrate(expression, own_tags)
        expr_dict = {k | prime_tags | sub_tags: v for k, v in expr_dict.items()}
        print("-", "AND", key, expr_dict, bool_vars)
        return key, expr_dict, bool_vars

    def walk_or(self, child_results, node):
        print("+", "OR", node.id, child_results)
        print(" ", "OR", *[child_result[1] for child_result in child_results])
        results = [(child_result[1][self.get_requested_tags(node.id, child_result[0])], child_result[2])
                   for child_result in child_results]
        # assert all(self.dependency[node.id][child_results[i][0]] == self.dependency[node.id][child_results[0][0]]
        #            for i in range(1, len(child_results)))
        result, bool_vars = results[0]
        for child_result, child_bool_vars in results[1:]:
            result = self.algebra.plus(result, child_result)
            bool_vars |= child_bool_vars
        expr_dict = {self.get_requested_tags(node.id, child_results[0][0]): result}
        print("-", "OR", node.id, expr_dict, bool_vars)
        return node.id, expr_dict, bool_vars

    def walk_literal(self, l, node):
        print("+", "LIT", node.id, l)

        if abs(l) in self.lit_to_var:
            expr, bool_vars = smt.TRUE(), {self.lit_to_var[abs(l)]}
        else:
            f = self.reverse_abstractions[abs(l)]
            if l < 0:
                f = ~f
            expr, bool_vars = LinearInequality.from_smt(f).to_expression(self.algebra), set()
        if node.id in self.integration_tags:
            expr_dict = self.integrate(expr, self.integration_tags.get(node.id, set()))
        else:
            expr_dict = {frozenset(): expr}
        print("-", "LIT", node.id, expr_dict, bool_vars)
        return node.id, expr_dict, bool_vars

    def integrate(self, expr, tags_set):
        # type: (Any, Set[Set[int]]) -> Dict[Set[int], Any]
        print("+", "INT", expr, list(tags_set))
        result = dict()
        for group_tags in tags_set:
            tags_result = expr
            for group_id in group_tags:
                variables, poly = self.groups[group_id]
                group_expr = self.algebra.times(tags_result, poly.to_expression(self.algebra))
                tags_result = self.algebra.integrate(self.domain, group_expr, variables)
            result[group_tags] = tags_result
        print("-", "INT", result)
        return result


def get_variable_groups_poly(weight: Polynomial, real_vars: List[str]) -> List[Tuple[Set[str], Polynomial]]:
    if len(real_vars) > 0:
        result = []
        found_vars = weight.variables
        for v in real_vars:
            if v not in found_vars:
                result.append((set(v), Polynomial.from_constant(1)))
        return result + get_variable_groups_poly(weight, [])

    if len(weight.poly_dict) > 1:
        return [(weight.variables, weight)]
    elif len(weight.poly_dict) == 0:
        return [(set(), Polynomial.from_constant(0))]
    else:
        result = []
        for name, value in weight.poly_dict.items():
            if len(name) == 0:
                result.append((set(), Polynomial.from_constant(value)))
            else:
                for v in name:
                    result.append(({v}, Polynomial.from_smt(smt.Symbol(v, smt.REAL))))
                result.append((set(), Polynomial.from_constant(value)))
        return result


def get_variable_groups(weight: FNode) -> List[Tuple[Set[str], FNode]]:
    if weight.is_symbol():
        return [({weight.symbol_name()}, weight)]
    elif weight.is_constant():
        return [(set(), weight)]
    elif weight.is_times():
        result = []
        for arg in weight.args():
            result += get_variable_groups(arg)
        return result
    else:
        return [({str(v) for v in weight.get_free_variables()}, weight)]


def tag_sdd(parent_to_children, node_to_groups, root_id):
    dependency = defaultdict(lambda: dict())
    integration_tags = defaultdict(lambda: set())
    push_bounds_down(parent_to_children, node_to_groups, root_id, dependency, integration_tags)
    return dict(dependency), dict(integration_tags)


def push_bounds_down(parent_to_children, node_to_groups, root_id, dependency, integration_tags, mode="OR", tags=None,
                     prefix=""):
    # type: (Dict, Dict, int, Dict, Dict, str, Set, str) -> None
    if tags is None:
        tags = node_to_groups[root_id]

    print(prefix, "Root", root_id, "with vars:", node_to_groups[root_id], "tags", tags)

    if len(tags) == 0 or len(tags - node_to_groups[root_id]) != 0:
        return

    if root_id not in parent_to_children:
        print(prefix, "Leaf {}".format(root_id))
        integration_tags[root_id].add(frozenset(tags))
        return

    children = parent_to_children[root_id]
    if mode == "OR":
        for child in children:
            dependency[root_id][child] = tags
            print(prefix, "[{}] Push tags {} to child {}".format(root_id, tags, child))
            push_bounds_down(parent_to_children, node_to_groups, child, dependency, integration_tags, "AND", tags,
                             prefix + " | ")
    else:
        groups1 = node_to_groups[children[0]]
        groups2 = node_to_groups[children[1]]
        shared = groups1 & groups2
        shared_tags = shared & tags
        if len(shared_tags) > 0:
            integration_tags[root_id].add(frozenset(shared_tags))
        tags1 = (groups1 - shared) & tags
        tags2 = (groups2 - shared) & tags
        print(prefix, "INT", shared & tags, "LEFT", tags1, "RIGHT", tags2)
        dependency[root_id][children[0]] = tags1
        dependency[root_id][children[1]] = tags2
        push_bounds_down(parent_to_children, node_to_groups, children[0], dependency, integration_tags, "OR", tags1,
                         prefix + " | ")
        push_bounds_down(parent_to_children, node_to_groups, children[1], dependency, integration_tags, "OR", tags2,
                         prefix + " | ")


class NativeXsddEngine(Engine):
    def __init__(self, domain, support, weight, backend: IntegrationBackend, manager=None):
        super().__init__(domain, support, weight, backend.exact)
        if SddManager is None:
            from pywmi.errors import InstallError
            raise InstallError("NativeXsddEngine requires the pysdd package")
        self.manager = manager or SddManager()
        self.backend = backend

    def get_samples(self, n):
        raise NotImplementedError()

    def integrate_convex(self, convex_support, polynomial_weight):
        try:
            domain = Domain(self.domain.real_vars, {v: REAL for v in self.domain.real_vars}, self.domain.var_domains)
            return self.backend.integrate(domain, BoundsWalker.get_inequalities(convex_support),
                                          Polynomial.from_smt(polynomial_weight))
        except ZeroDivisionError:
            return 0

    def compute_volume(self, pint=False):
        abstractions, var_to_lit = dict(), dict()

        # conflicts = []
        # inequalities = list(BoundsWalker(True).walk_smt(self.support) | BoundsWalker(True).walk_smt(self.weight))
        # for i in range(len(inequalities) - 1):
        #     for j in range(i + 1, len(inequalities)):
        #         # TODO Find conflicts
        #         if implies(inequalities[i], inequalities[j]):
        #             conflicts.append(smt.Implies(inequalities[i], inequalities[j]))
        #             print(inequalities[i], "=>", inequalities[j])
        #         if implies(inequalities[j], inequalities[i]):
        #             conflicts.append(smt.Implies(inequalities[j], inequalities[i]))
        #             print(inequalities[j], "=>", inequalities[i])

        algebra = PolynomialAlgebra()
        support_sdd = convert_formula(self.support, self.manager, algebra, abstractions, var_to_lit)
        piecewise_function = convert_function(self.weight, self.manager, algebra, abstractions, var_to_lit)

        volume = 0
        for world_weight, world_support in piecewise_function.sdd_dict.items():

            support = support_sdd & world_support
            if pint:
                print(pretty_print(recover_formula(support, abstractions, var_to_lit, False)))

                print(world_weight)
                variable_groups = get_variable_groups_poly(world_weight, self.domain.real_vars)

                def get_group(_v):
                    for i, (_vars, _node) in enumerate(variable_groups):
                        if _v in _vars:
                            return i
                    raise ValueError("Variable {} not found in any group ({})".format(_v, variable_groups))

                print(variable_groups)
                child_to_parents_mapping = ParentAnalysis.get_parents(abstractions, var_to_lit, support)
                parent_to_children_mapping = ParentAnalysis.get_children(abstractions, var_to_lit, support)
                print(parent_to_children_mapping)

                print()
                literal_to_groups = dict()
                for inequality, literal in abstractions.items():
                    inequality_variables = LinearInequality.from_smt(inequality).variables
                    inequality_groups = [get_group(v) for v in inequality_variables]
                    literal_to_groups[literal] = inequality_groups

                print("Literal -> groups", literal_to_groups)

                tag_analysis = VariableTagAnalysis(literal_to_groups)
                walk(tag_analysis, support)
                node_to_groups = tag_analysis.node_to_groups
                print("Node -> groups", node_to_groups)

                print()
                dependency, integration_tags = tag_sdd(parent_to_children_mapping, node_to_groups, support.id)
                print("Dependency", dependency)
                print("Tags", integration_tags)

                group_to_vars_poly = {i: g for i, g in enumerate(variable_groups)}
                print("RESULT",
                      walk(FactorizedWMIWalker(self.domain, abstractions, var_to_lit, group_to_vars_poly, dependency,
                                               integration_tags), support))

                exit(0)
                continuous_vars = ContinuousVars(abstractions, var_to_lit)
                amc(continuous_vars, support)
                print(*["{}: {}".format(k, v) for k, v in continuous_vars.index_to_real_vars.items()], sep="\n")

                semiring_conprov = ContinuousProvenanceSemiring(abstractions, var_to_lit)
                result = amc(semiring_conprov, support)
                for index, variables in semiring_conprov.index_to_conprov.items():
                    print(self.manager, variables)

                import sys
                sys.exit()
                semiring_inttags = IntTagSemiring(abstractions, var_to_lit, semiring_conprov.index_to_conprov)
                _ = amc(semiring_inttags, support)
                int_tags = semiring_inttags.int_tags
                int_tags = {}
                # TODO fill int tags correctly
                convex_supports = amc(WMISemiringPint(abstractions, var_to_lit, int_tags), support)
                for convex_support, variables in convex_supports:
                    missing_variable_count = len(self.domain.bool_vars) - len(variables)
                    vol = self.integrate_convex(convex_support, world_weight.to_smt()) * 2 ** missing_variable_count
                    volume += vol
            else:
                convex_supports = amc(WMISemiring(abstractions, var_to_lit), support)
                for convex_support, variables in convex_supports:
                    missing_variable_count = len(self.domain.bool_vars) - len(variables)
                    vol = self.integrate_convex(convex_support, world_weight.to_smt()) * 2 ** missing_variable_count
                    volume += vol

        return volume

    def copy(self, domain, support, weight):
        return NativeXsddEngine(self.domain, support, weight, self.manager)

    def __str__(self):
        return "n-xsdd:b{}".format(self.backend)
