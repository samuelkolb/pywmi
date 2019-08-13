from antlr4 import *
from pysmt.shortcuts import *
import io

from .antlr.smtlibLexer import smtlibLexer
from .antlr.smtlibParser import smtlibParser
from .visitor import Visitor
from .smtlibErrorListener import SmtlibErrorListener

class SmtlibParser():

    @staticmethod
    def parse(path, domA=None, domX=None):
        if domA is None:
            domA = []
        if domX is None:
            domX = []
        
        # init lexer and parser
        smt_file = FileStream(path)
        lexer = smtlibLexer(smt_file)
        stream = CommonTokenStream(lexer)
        parser = smtlibParser(stream)
        
        # add custom error listener
        parser.removeErrorListeners()
        errorListener = SmtlibErrorListener()
        parser.addErrorListener(errorListener)
        
        # compute parsing
        tree = parser.start()
        
        # visit the tree
        visitor = Visitor(domA=domA, domX=domX)
        return visitor.visit(tree)
