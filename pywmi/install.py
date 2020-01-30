import argparse
import os
import shutil
import urllib.request
import zipfile

import tabulate
from pysmt.exceptions import NoSolverAvailableError
from pysmt.shortcuts import Solver

from pywmi.temp import TemporaryFile


def check_installation_pysdd():
    try:
        import pysdd
        return True
    except ImportError:
        return False


def check_installation_psi():
    try:
        import psipy
        return True
    except ImportError:
        return False


def check_installation_smt_solver():
    try:
        with Solver():
            return True
    except NoSolverAvailableError:
        return False


def check_installation_gurobi():
    if not shutil.which("gurobi"):
        return False
    return True


def check_installation_latte():
    if not shutil.which("integrate"):
        return False
    return True


def install_xadd(upgrade=False, remove=False):
    file_name = os.path.join(os.path.dirname(__file__), "engines", "xadd.jar")
    if remove:
        if os.path.exists(file_name):
            os.unlink(file_name)
            print("Removed XADD solver at {}".format(file_name))
        else:
            print("XADD solver is not installed")

    if not upgrade and os.path.exists(file_name):
        print("XADD solver already installed")
    else:
        print("Downloading JAR file to {}".format(file_name))
        url = "https://www.dropbox.com/s/e33axb83ftghrfb/xadd.jar?dl=1"
        with urllib.request.urlopen(url) as response, open(file_name, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)


def install_pa(upgrade=False, remove=False):
    url = "https://github.com/unitn-sml/wmi-pa/archive/master.zip"
    file_name = os.path.join(os.path.dirname(__file__), "engines", "lib", "pa")

    if remove:
        if os.path.exists(file_name):
            shutil.rmtree(file_name)
            print("Removed PA solver at {}".format(file_name))
        else:
            print("PA solver is not installed")

    if not upgrade and os.path.exists(file_name):
        print("PA solver already installed")
    else:
        with TemporaryFile() as zip_name:
            print("Downloading ZIP file to {}".format(zip_name))
            with urllib.request.urlopen(url) as response, open(zip_name, 'wb') as out_file:
                shutil.copyfileobj(response, out_file)

            if os.path.exists(file_name):
                shutil.rmtree(file_name)
            os.makedirs(file_name)
            print("Extracting ZIP file to {}".format(file_name))
            with zipfile.ZipFile(zip_name, 'r') as zip_ref:
                zip_ref.extractall(file_name)
        print("Deleted ZIP file")


def main():
    parser = argparse.ArgumentParser(description="Installation utility for install external requirements")
    parser.add_argument("solver", nargs='?', help="Specify the solver to install, options are: [xadd, pa]")
    parser.add_argument("-f", "--force", action="store_true", help="Reinstall solver if it already exists")
    parser.add_argument("-r", "--remove", action="store_true", help="Remove solver")
    parser.add_argument("-l", "--list", action="store_true", help="Remove solver")

    args = parser.parse_args()
    if args.solver is None and args.list:
        solvers = [
            ("XSDD / F-XSDD", ["pysdd", "psi"]),
            ("XADD", ["gurobi", "smt_solver"]),
            ("pyxadd", ["psi", "smt_solver"]),
            ("pa", ["wmipa", "latte"])
        ]

        def check_solvers(_comp):
            return ", ".join([solver[0] for solver in solvers if _comp in solver[1]])

        print(tabulate.tabulate([
            ["pysdd", "installed" if check_installation_pysdd() else "not installed", check_solvers("pysdd")],
            ["PSI", "installed" if check_installation_psi() else "not installed", check_solvers("psi")],
            ["SMT Solver", "installed" if check_installation_smt_solver() else "not installed", check_solvers("smt_solver")],
            ["Gurobi", "installed" if check_installation_gurobi() else "not installed",
             check_solvers("gurobi")],
            ["Latte", "installed" if check_installation_latte() else "not installed",
             check_solvers("latte")],

        ], headers=["Component", "Status", "Used by"]))
    elif args.solver == "xadd":
        install_xadd(args.force, args.remove)
    elif args.solver == "pa":
        install_pa(args.force, args.remove)
    else:
        print("Unknown solver {}".format(args.solver))


if __name__ == "__main__":
    main()
