// Written in the D programming language
// License: http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0

import std.array,std.algorithm,std.range;
import std.format, std.conv;
import lexer,scope_,expression,type,declaration,error,dutil;

alias CommaExp=BinaryExp!(Tok!",");
alias AssignExp=BinaryExp!(Tok!"←");
alias OrAssignExp=BinaryExp!(Tok!"||←");
alias AndAssignExp=BinaryExp!(Tok!"&&←");
alias AddAssignExp=BinaryExp!(Tok!"+←");
alias SubAssignExp=BinaryExp!(Tok!"-←");
alias MulAssignExp=BinaryExp!(Tok!"·←");
alias DivAssignExp=BinaryExp!(Tok!"/←");
alias IDivAssignExp=BinaryExp!(Tok!"div←");
alias ModAssignExp=BinaryExp!(Tok!"%←");
alias PowAssignExp=BinaryExp!(Tok!"^←");
alias CatAssignExp=BinaryExp!(Tok!"~←");
alias BitOrAssignExp=BinaryExp!(Tok!"∨←");
alias BitXorAssignExp=BinaryExp!(Tok!"⊕←");
alias BitAndAssignExp=BinaryExp!(Tok!"∧←");
alias AddExp=BinaryExp!(Tok!"+");
alias SubExp=BinaryExp!(Tok!"-");
alias MulExp=BinaryExp!(Tok!"·");
alias DivExp=BinaryExp!(Tok!"/");
alias IDivExp=BinaryExp!(Tok!"div");
alias ModExp=BinaryExp!(Tok!"%");
alias PowExp=BinaryExp!(Tok!"^");
alias CatExp=BinaryExp!(Tok!"~");
alias BitOrExp=BinaryExp!(Tok!"∨");
alias BitXorExp=BinaryExp!(Tok!"⊕");
alias BitAndExp=BinaryExp!(Tok!"∧");
alias UMinusExp=UnaryExp!(Tok!"-");
alias UNotExp=UnaryExp!(Tok!"¬");
alias UBitNotExp=UnaryExp!(Tok!"~");
alias LtExp=BinaryExp!(Tok!"<");
alias LeExp=BinaryExp!(Tok!"≤");
alias GtExp=BinaryExp!(Tok!">");
alias GeExp=BinaryExp!(Tok!"≥");
alias EqExp=BinaryExp!(Tok!"=");
alias NeqExp=BinaryExp!(Tok!"≠");
alias OrExp=BinaryExp!(Tok!"||");
alias AndExp=BinaryExp!(Tok!"&&");
alias Exp=Expression;

void propErr(Expression e1,Expression e2){
	if(e1.sstate==SemState.error) e2.sstate=SemState.error;
}

DataScope isInDataScope(Scope sc){
	auto asc=cast(AggregateScope)sc;
	if(asc) return cast(DataScope)asc.parent;
	return null;
}

AggregateTy isDataTyId(Expression e){
	if(auto ce=cast(CallExp)e)
		return isDataTyId(ce.e);
	if(auto id=cast(Identifier)e)
		if(auto decl=cast(DatDecl)id.meaning)
			return decl.dtype;
	if(auto fe=cast(FieldExp)e)
		if(auto decl=cast(DatDecl)fe.f.meaning)
			return decl.dtype;
	return null;
}

void declareParameters(Expression parent,bool isSquare,Parameter[] params,Scope sc){
	foreach(ref p;params){
		if(!p.dtype){ // ℝ is the default parameter type for () and * is the default parameter type for []
			p.dtype=New!Identifier(isSquare?"*":"ℝ");
			p.dtype.loc=p.loc;
		}
		p=cast(Parameter)varDeclSemantic(p,sc);
		assert(!!p);
		propErr(p,parent);
	}
}

Expression presemantic(Declaration expr,Scope sc){
	bool success=true; // dummy
	if(!expr.scope_) makeDeclaration(expr,success,sc);
	static VarDecl addVar(string name,Expression ty,Location loc,Scope sc){
		auto id=new Identifier(name);
		id.loc=loc;
		auto var=new VarDecl(id);
		var.loc=loc;
		var.vtype=ty;
		var=varDeclSemantic(var,sc);
		assert(!!var && var.sstate==SemState.completed);
		return var;
	}
	if(auto dat=cast(DatDecl)expr){
		if(dat.dtype) return expr;
		auto dsc=new DataScope(sc,dat);
		assert(!dat.dscope_);
		dat.dscope_=dsc;
		dat.dtype=new AggregateTy(dat);
		if(dat.hasParams) declareParameters(dat,true,dat.params,dsc);
		if(!dat.body_.ascope_) dat.body_.ascope_=new AggregateScope(dat.dscope_);
		if(cast(NestedScope)sc) dat.context = addVar("`outer",contextTy(),dat.loc,dsc);
		foreach(ref exp;dat.body_.s) exp=makeDeclaration(exp,success,dat.body_.ascope_);
		foreach(ref exp;dat.body_.s) if(auto decl=cast(Declaration)exp) exp=presemantic(decl,dat.body_.ascope_);
	}
	if(auto fd=cast(FunctionDef)expr){
		if(fd.fscope_) return fd;
		auto fsc=new FunctionScope(sc,fd);
		fd.type=unit;
		fd.fscope_=fsc;
		assert(!fd.body_.blscope_);
		fd.body_.blscope_=new BlockScope(fsc);
		if(auto dsc=isInDataScope(sc)){
			auto id=new Identifier(dsc.decl.name.name);
			id.loc=dsc.decl.loc;
			id.meaning=dsc.decl;
			id=cast(Identifier)expressionSemantic(id,sc);
			assert(!!id);
			Expression ctxty=id;
			if(dsc.decl.hasParams){
				auto args=dsc.decl.params.map!((p){
					auto id=new Identifier(p.name.name);
					id.meaning=p;
					auto r=expressionSemantic(id,sc);
					assert(r.sstate==SemState.completed);
					return r;
				}).array;
				assert(dsc.decl.isTuple||args.length==1);
				ctxty=callSemantic(new CallExp(ctxty,dsc.decl.isTuple?new TupleExp(args):args[0],true),sc);
				ctxty.sstate=SemState.completed;
				assert(ctxty.type == typeTy);
			}
			if(dsc.decl.name.name==fd.name.name){
				assert(!!fd.body_.blscope_);
				auto thisVar=addVar("this",ctxty,fd.loc,fd.body_.blscope_); // the 'this' variable
				fd.isConstructor=true;
				if(fd.rret){
					sc.error("constructor cannot have return type annotation",fd.loc);
					fd.sstate=SemState.error;
				}else{
					assert(dsc.decl.dtype);
					fd.ret=ctxty;
				}
				if(!fd.body_.s.length||!cast(ReturnExp)fd.body_.s[$-1]){
					auto thisid=new Identifier(thisVar.getName);
					thisid.loc=fd.loc;
					thisid.scope_=fd.body_.blscope_;
					thisid.meaning=thisVar;
					thisid.type=ctxty;
					thisid.sstate=SemState.completed;
					auto rete=new ReturnExp(thisid);
					rete.loc=thisid.loc;
					rete.sstate=SemState.completed;
					fd.body_.s~=rete;
				}
				if(dsc.decl.context){
					fd.context=dsc.decl.context; // TODO: ok?
					fd.contextVal=dsc.decl.context; // TODO: ok?
				}
				fd.thisVar=thisVar;
			}else{
				fd.contextVal=addVar("this",unit,fd.loc,fsc); // the 'this' value
				assert(!!fd.body_.blscope_);
				fd.context=addVar("this",ctxty,fd.loc,fd.body_.blscope_);
			}
			assert(dsc.decl.dtype);
		}else if(auto nsc=cast(NestedScope)sc){
			fd.contextVal=addVar("`outer",contextTy(),fd.loc,fsc); // TODO: replace contextTy by suitable record type; make name 'outer' available
			fd.context=fd.contextVal;
		}
		declareParameters(fd,fd.isSquare,fd.params,fsc); // parameter variables
		if(fd.rret){
			string[] pn;
			Expression[] pty;
			foreach(p;fd.params){
				if(!p.vtype){
					assert(fd.sstate==SemState.error);
					return fd;
				}
				pn~=p.getName;
				pty~=p.vtype;
			}
			fd.ret=typeSemantic(fd.rret,fsc);
			assert(fd.isTuple||pty.length==1);
			auto pt=fd.isTuple?tupleTy(pty):pty[0];
			if(!fd.ret) fd.sstate=SemState.error;
			else fd.ftype=productTy(pn,pt,fd.ret,fd.isSquare,fd.isTuple);
		}
	}
	return expr;
}

int importModule(string path,ErrorHandler err,out Expression[] exprs,out TopScope sc,Location loc=Location.init){
	import std.typecons: tuple,Tuple;
	static Tuple!(Expression[],TopScope)[string] modules;
	if(path in modules){
		auto exprssc=modules[path];
		exprs=exprssc[0],sc=exprssc[1];
		if(!sc){
			if(loc.line) err.error("circular imports not supported",loc);
			else stderr.writeln("error: circular imports not supported",loc);
			return 1;
		}
		return 0;
	}
	modules[path]=tuple(Expression[].init,TopScope.init);
	scope(success) modules[path]=tuple(exprs,sc);
	TopScope prsc=null;
	Expression[] prelude;
	import parser;
	if(!prsc && path != preludePath())
		if(auto r=importModule(preludePath,err,prelude,prsc))
			return r;
	if(auto r=parseFile(getActualPath(path),err,exprs,loc))
		return r;
	sc=new TopScope(err);
	if(prsc) sc.import_(prsc);
	int nerr=err.nerrors;
	exprs=semantic(exprs,sc);
	return nerr!=err.nerrors;
}

Expression makeDeclaration(Expression expr,ref bool success,Scope sc){
	if(auto imp=cast(ImportExp)expr){
		imp.scope_ = sc;
		auto ctsc=cast(TopScope)sc;
		if(!ctsc){
			sc.error("nested imports not supported",imp.loc);
			imp.sstate=SemState.error;
			return imp;
		}
		foreach(p;imp.e){
			auto path = getActualPath(ImportExp.getPath(p));
			Expression[] exprs;
			TopScope tsc;
			if(importModule(path,sc.handler,exprs,tsc,imp.loc))
				imp.sstate=SemState.error;
			if(tsc) ctsc.import_(tsc);
		}
		if(imp.sstate!=SemState.error) imp.sstate=SemState.completed;
		return imp;
	}
	if(auto decl=cast(Declaration)expr){
		if(!decl.scope_) success&=sc.insert(decl);
		return decl;
	}
	if(auto ce=cast(CommaExp)expr){
		ce.e1=makeDeclaration(ce.e1,success,sc);
		propErr(ce.e1,ce);
		ce.e2=makeDeclaration(ce.e2,success,sc);
		propErr(ce.e2,ce);
		return ce;
	}
	if(auto be=cast(BinaryExp!(Tok!":="))expr){
		if(auto id=cast(Identifier)be.e1){
			auto nid=new Identifier(id.name);
			nid.loc=id.loc;
			auto vd=new VarDecl(nid);
			vd.loc=id.loc;
			success&=sc.insert(vd);
			id.name=vd.getName;
			id.scope_=sc;
			auto de=new SingleDefExp(vd,be);
			de.loc=be.loc;
			propErr(vd,de);
			return de;
		}else if(auto tpl=cast(TupleExp)be.e1){
			VarDecl[] vds;
			foreach(exp;tpl.e){
				auto id=cast(Identifier)exp;
				if(!id) goto LnoIdTuple;
				auto nid=new Identifier(id.name);
				nid.loc=id.loc;
				vds~=new VarDecl(nid);
				vds[$-1].loc=id.loc;
				success&=sc.insert(vds[$-1]);
				id.name=vds[$-1].getName;
				id.scope_=sc;
			}
			auto de=new MultiDefExp(vds,be);
			de.loc=be.loc;
			foreach(vd;vds) propErr(vd,de);
			return de;
		}else LnoIdTuple:{
			sc.error("left hand side of definition must be identifier or tuple of identifiers",expr.loc);
			success=false;
		}
		success&=expr.sstate==SemState.completed;
		return expr;
	}
	if(auto tae=cast(TypeAnnotationExp)expr){
		if(auto id=cast(Identifier)tae.e){
			auto vd=new VarDecl(id);
			vd.loc=tae.loc;
			vd.dtype=tae.t;
			vd.vtype=typeSemantic(vd.dtype,sc);
			vd.loc=id.loc;
			success&=sc.insert(vd);
			id.name=vd.getName;
			id.scope_=sc;
			return vd;
		}
	}
	sc.error("not a declaration: "~expr.toString()~" ",expr.loc);
	expr.sstate=SemState.error;
	success=false;
	return expr;
}

Expression[] semantic(Expression[] exprs,Scope sc){
	bool success=true;
	foreach(ref expr;exprs) if(!cast(BinaryExp!(Tok!":="))expr&&!cast(CommaExp)expr) expr=makeDeclaration(expr,success,sc); // TODO: get rid of special casing?
	foreach(ref expr;exprs) if(auto decl=cast(Declaration)expr) expr=presemantic(decl,sc);
	foreach(ref expr;exprs){
		expr=toplevelSemantic(expr,sc);
		success&=expr.sstate==SemState.completed;
	}
	return exprs;
}

Expression toplevelSemantic(Expression expr,Scope sc){
	if(expr.sstate==SemState.error) return expr;
	if(auto fd=cast(FunctionDef)expr) return functionDefSemantic(fd,sc);
	if(auto dd=cast(DatDecl)expr) return datDeclSemantic(dd,sc);
	if(cast(BinaryExp!(Tok!":="))expr||cast(DefExp)expr) return colonOrAssignSemantic(expr,sc);
	if(auto ce=cast(CommaExp)expr) return expectColonOrAssignSemantic(ce,sc);
	if(auto imp=cast(ImportExp)expr){
		assert(dutil.among(imp.sstate,SemState.error,SemState.completed));
		return imp;
	}
	sc.error("not supported at toplevel",expr.loc);
	expr.sstate=SemState.error;
	return expr;
}

bool isBuiltIn(Identifier id){
	if(!id||id.meaning) return false;
	switch(id.name){
	case "π":
	case "readCSV":
	case "Marginal","sampleFrom":
	case "Expectation":
		return true;
	case "*","𝟙",/*"𝟚","B","𝔹","Z","ℤ","Q","ℚ",*/"R","ℝ":
		return true;
	default: return false;
	}
}

Expression distributionTy(Expression base,Scope sc){
	return typeSemantic(new CallExp(varTy("Distribution",funTy(typeTy,typeTy,true,false)),base,true),sc);
}

Expression builtIn(Identifier id,Scope sc){
	Expression t=null;
	switch(id.name){
	case "readCSV": t=funTy(stringTy,arrayTy(ℝ),false,false); break;
	case "π": t=ℝ; break;
	case "Marginal","sampleFrom": t=unit; break; // those are actually magic polymorphic functions
	case "Expectation": t=funTy(ℝ,ℝ,false,false); break;
	case "*","𝟙","𝟚","B","𝔹","Z","ℤ","Q","ℚ","R","ℝ":
		id.type=typeTy;
		if(id.name=="*") return typeTy;
		if(id.name=="𝟙") return unit;
		// TODO:
		//if(id.name=="𝟚"||id.name=="B"||id.name=="𝔹") return Bool;
		//if(id.name=="Z"||id.name=="ℤ") return ℤt;
		//if(id.name=="Q"||id.name=="ℚ") return ℚt;
		if(id.name=="R"||id.name=="ℝ") return ℝ;
	default: return null;
	}
	id.type=t;
	id.sstate=SemState.completed;
	return id;
}

bool isBuiltIn(FieldExp fe)in{
	assert(fe.e.sstate==SemState.completed);
}body{
	if(fe.f.meaning) return false;
	if(auto at=cast(ArrayTy)fe.e.type){
		if(fe.f.name=="length"){
			return true;
		}
	}
	return false;
}

Expression builtIn(FieldExp fe,Scope sc)in{
	assert(fe.e.sstate==SemState.completed);
}body{
	if(fe.f.meaning) return null;
	if(auto at=cast(ArrayTy)fe.e.type){
		if(fe.f.name=="length"){
			fe.type=ℝ;
			fe.f.sstate=SemState.completed;
			return fe;
		}else return null;
	}
	return null;
}

bool isFieldDecl(Expression e){
	if(cast(VarDecl)e) return true;
	if(auto tae=cast(TypeAnnotationExp)e)
		if(auto id=cast(Identifier)tae.e)
			return true;
	return false;
}

Expression fieldDeclSemantic(Expression e,Scope sc)in{
	assert(isFieldDecl(e));
}body{
	e.sstate=SemState.completed;
	return e;
}

Expression expectFieldDeclSemantic(Expression e,Scope sc){
	if(auto ce=cast(CommaExp)e){
		ce.e1=expectFieldDeclSemantic(ce.e1,sc);
		ce.e2=expectFieldDeclSemantic(ce.e2,sc);
		propErr(ce.e1,ce);
		propErr(ce.e2,ce);
		return ce;
	}
	if(isFieldDecl(e)) return fieldDeclSemantic(e,sc);
	sc.error("expected field declaration",e.loc);
	e.sstate=SemState.error;
	return e;
}

Expression nestedDeclSemantic(Expression e,Scope sc){
	if(auto fd=cast(FunctionDef)e)
		return functionDefSemantic(fd,sc);
	if(auto dd=cast(DatDecl)e)
		return datDeclSemantic(dd,sc);
	if(isFieldDecl(e)) return fieldDeclSemantic(e,sc);
	if(auto ce=cast(CommaExp)e) return expectFieldDeclSemantic(ce,sc);
	sc.error("not a declaration",e.loc);
	e.sstate=SemState.error;
	return e;
}

CompoundDecl compoundDeclSemantic(CompoundDecl cd,Scope sc){
	auto asc=cd.ascope_;
	if(!asc) asc=new AggregateScope(sc);
	cd.ascope_=asc;
	bool success=true; // dummy
	foreach(ref e;cd.s) e=makeDeclaration(e,success,asc);
	foreach(ref e;cd.s) if(auto decl=cast(Declaration)e) e=presemantic(decl,asc);
	foreach(ref e;cd.s){
		e=nestedDeclSemantic(e,asc);
		propErr(e,cd);
	}
	cd.type=unit;
	return cd;	
}

Expression statementSemantic(Expression e,Scope sc){
	alias Bool=ℝ; // TODO: maybe add 𝟚 as specific boolean type?
	if(auto ce=cast(CallExp)e)
		return callSemantic(ce,sc);
	if(auto ite=cast(IteExp)e){
		ite.cond=expressionSemantic(ite.cond,sc);
		ite.then=compoundExpSemantic(ite.then,sc);
		if(ite.othw) ite.othw=compoundExpSemantic(ite.othw,sc);
		if(ite.cond.sstate==SemState.completed && ite.cond.type!is Bool){
			sc.error(format("cannot obtain truth value for type %s",ite.cond.type),ite.cond.loc);
			ite.sstate=SemState.error;
		}
		propErr(ite.cond,ite);
		propErr(ite.then,ite);
		if(ite.othw) propErr(ite.othw,ite);
		ite.type=unit;
		return ite;
	}
	if(auto ret=cast(ReturnExp)e)
		return returnExpSemantic(ret,sc);
	if(auto fd=cast(FunctionDef)e)
		return functionDefSemantic(fd,sc);
	if(auto dd=cast(DatDecl)e)
		return datDeclSemantic(dd,sc);
	if(auto ce=cast(CommaExp)e) return expectColonOrAssignSemantic(ce,sc);
	if(isColonOrAssign(e)) return colonOrAssignSemantic(e,sc);
	if(auto fe=cast(ForExp)e){
		auto fesc=new ForExpScope(sc,fe);
		auto vd=new VarDecl(fe.var);
		vd.vtype=ℝ;
		vd.loc=fe.var.loc;
		if(!fesc.insert(vd))
			fe.sstate=SemState.error;
		fe.var.name=vd.getName;
		fe.fescope_=fesc;
		fe.loopVar=vd;
		fe.left=expressionSemantic(fe.left,sc);
		if(fe.left.sstate==SemState.completed && fe.left.type!is ℝ){
			sc.error(format("lower bound for loop variable should be a number, not %s",fe.left.type),fe.left.loc);
			fe.sstate=SemState.error;
		}
		fe.right=expressionSemantic(fe.right,sc);
		if(fe.right.sstate==SemState.completed && fe.right.type!is ℝ){
			sc.error(format("upper bound for loop variable should be a number, not %s",fe.right.type),fe.right.loc);
			fe.sstate=SemState.error;
		}
		fe.bdy=compoundExpSemantic(fe.bdy,fesc);
		assert(!!fe.bdy);
		propErr(fe.left,fe);
		propErr(fe.right,fe);
		fe.type=unit;
		return fe;
	}
	if(auto we=cast(WhileExp)e){
		we.cond=expressionSemantic(we.cond,sc);
		we.bdy=compoundExpSemantic(we.bdy,sc);
		propErr(we.cond,we);
		propErr(we.bdy,we);
		we.type=unit;
		return we;
	}
	if(auto re=cast(RepeatExp)e){
		re.num=expressionSemantic(re.num,sc);
		if(re.num.sstate==SemState.completed && re.num.type!is ℝ){
			sc.error(format("number of iterations should be a number, not %s",re.num.type),re.num.loc);
			re.sstate=SemState.error;
		}
		re.bdy=compoundExpSemantic(re.bdy,sc);
		propErr(re.num,re);
		propErr(re.bdy,re);
		re.type=unit;
		return re;
	}
	if(auto oe=cast(ObserveExp)e){
		oe.e=expressionSemantic(oe.e,sc);
		if(oe.e.sstate==SemState.completed && oe.e.type!is Bool){
			sc.error(format("cannot obtain truth value for type %s",oe.e.type),oe.e.loc);
			oe.sstate=SemState.error;
		}
		propErr(oe.e,oe);
		oe.type=unit;
		return oe;
	}
	if(auto oe=cast(CObserveExp)e){ // TODO: get rid of cobserve!
		oe.var=expressionSemantic(oe.var,sc);
		oe.val=expressionSemantic(oe.val,sc);
		propErr(oe.var,oe);
		propErr(oe.val,oe);
		if(oe.sstate==SemState.error)
			return oe;
		if(oe.var.type!is ℝ || oe.val.type !is ℝ){
			sc.error("both arguments to cobserve should be real numbers",oe.loc);
			oe.sstate=SemState.error;
		}
		oe.type=unit;
		return oe;
	}
	if(auto ae=cast(AssertExp)e){
		ae.e=expressionSemantic(ae.e,sc);
		if(ae.e.sstate==SemState.completed && ae.e.type!is Bool){
			sc.error(format("cannot obtain truth value for type %s",ae.e.type),ae.e.loc);
			ae.sstate=SemState.error;
		}
		propErr(ae.e,ae);
		ae.type=unit;
		return ae;
	}
	sc.error("not supported at this location",e.loc);
	e.sstate=SemState.error;
	return e;	
}

CompoundExp compoundExpSemantic(CompoundExp ce,Scope sc){
	if(!ce.blscope_) ce.blscope_=new BlockScope(sc);
	foreach(ref e;ce.s){
		e=statementSemantic(e,ce.blscope_);
		propErr(e,ce);
	}
	ce.type=unit;
	return ce;
}

VarDecl varDeclSemantic(VarDecl vd,Scope sc){
	bool success=true;
	if(!vd.scope_) makeDeclaration(vd,success,sc);
	vd.type=unit;
	if(!success) vd.sstate=SemState.error;
	if(!vd.vtype){
		assert(vd.dtype,text(vd));
		vd.vtype=typeSemantic(vd.dtype,sc);
	}
	if(!vd.vtype) vd.sstate=SemState.error;
	if(vd.sstate!=SemState.error)
		vd.sstate=SemState.completed;
	return vd;
}

Expression colonAssignSemantic(BinaryExp!(Tok!":=") be,Scope sc){
	bool success=true;
	if(auto ce=cast(CallExp)be.e2){
		if(auto id=cast(Identifier)ce.e){
			if(id.name=="array" && !ce.isSquare){
				ce.arg=expressionSemantic(ce.arg,sc);
				if(ce.arg.type==ℝ){
					ce.e.type=funTy(ℝ,arrayTy(ℝ),false,false);
					ce.e.sstate=SemState.completed;
				}
			}
		}
	}
	auto de=cast(DefExp)makeDeclaration(be,success,sc);
	if(!de) be.sstate=SemState.error;
	assert(success && de && de.initializer is be || !de||de.sstate==SemState.error);
	auto e2orig=be.e2;
	be.e2=expressionSemantic(be.e2,sc);
	if(be.e2.sstate==SemState.completed){
		if(auto tpl=cast(TupleExp)be.e1){
			if(auto tt=cast(TupleTy)be.e2.type){
				if(tpl.length!=tt.types.length){
					sc.error(text("inconsistent number of tuple entries for definition: ",tpl.length," vs. ",tt.types.length),de.loc);
					if(de){ de.setError(); be.sstate=SemState.error; }
				}
			}else{
				sc.error(format("cannot unpack type %s as a tuple",be.e2.type),de.loc);
				if(de){ de.setError(); be.sstate=SemState.error; }
			}
		}
		if(de){
			if(de.sstate!=SemState.error){
				de.setType(be.e2.type);
				de.setInitializer();
			}
			de.type=unit;
		}
		if(cast(TopScope)sc){
			if(!be.e2.isConstant() && !cast(PlaceholderExp)be.e2){
				sc.error("global constant initializer must be a constant",e2orig.loc);
				if(de){ de.setError(); be.sstate=SemState.error; }
			}
		}
	}else if(de) de.setError();
	auto r=de?de:be;
	if(r.sstate!=SemState.error) r.sstate=SemState.completed;
	return r;
}

bool checkAssignable(Declaration meaning,Location loc,Scope sc){
	if(!cast(VarDecl)meaning){
		sc.error("can only assign to variables",loc);
		return false;
	}else if(cast(Parameter)meaning){
		sc.error("cannot reassign parameters (use :=)",loc);
		return false;
	}else for(auto csc=sc;csc !is meaning.scope_;csc=(cast(NestedScope)csc).parent){
		if(auto fsc=cast(FunctionScope)csc){
			// TODO: what needs to be done to lift this restriction?
			// TODO: method calls are also implicit assignments.
			sc.error("cannot assign to variable in closure context (capturing by value)",loc);
			return false;
		}
	}
	return true;
}

AssignExp assignExpSemantic(AssignExp ae,Scope sc){
	ae.type=unit;
	ae.e1=expressionSemantic(ae.e1,sc);
	ae.e2=expressionSemantic(ae.e2,sc);
	propErr(ae.e1,ae);
	propErr(ae.e2,ae);
	if(ae.sstate==SemState.error)
		return ae;
	void checkLhs(Expression lhs){
		if(auto id=cast(Identifier)lhs){
			if(!checkAssignable(id.meaning,ae.loc,sc))
				ae.sstate=SemState.error;
		}else if(auto tpl=cast(TupleExp)lhs){
			foreach(ref exp;tpl.e)
				checkLhs(exp);
		}else if(auto idx=cast(IndexExp)lhs){
			checkLhs(idx.e);
		}else if(auto fe=cast(FieldExp)lhs){
			checkLhs(fe.e);
		}else if(auto tae=cast(TypeAnnotationExp)lhs){
			checkLhs(tae.e);
		}else{
		LbadAssgnmLhs:
			sc.error(format("cannot assign to %s",lhs),ae.e1.loc);
			ae.sstate=SemState.error;
		}
	}
	checkLhs(ae.e1);
	if(ae.sstate!=SemState.error&&!compatible(ae.e1.type,ae.e2.type)){
		if(auto id=cast(Identifier)ae.e1){
			sc.error(format("cannot assign %s to variable %s of type %s",ae.e2.type,id,id.type),ae.loc);
			assert(!!id.meaning);
			sc.note("declared here",id.meaning.loc);
		}else sc.error(format("cannot assign %s to %s",ae.e2.type,ae.e1.type),ae.loc);
		ae.sstate=SemState.error;
	}
	if(ae.sstate!=SemState.error) ae.sstate=SemState.completed;
	return ae;
}

bool isOpAssignExp(Expression e){
	return cast(OrAssignExp)e||cast(AndAssignExp)e||cast(AddAssignExp)e||cast(SubAssignExp)e||cast(MulAssignExp)e||cast(DivAssignExp)e||cast(IDivAssignExp)e||cast(ModAssignExp)e||cast(PowAssignExp)e||cast(CatAssignExp)e||cast(BitOrAssignExp)e||cast(BitXorAssignExp)e||cast(BitAndAssignExp)e;
}

ABinaryExp opAssignExpSemantic(ABinaryExp be,Scope sc)in{
	assert(isOpAssignExp(be));
}body{
	be.e1=expressionSemantic(be.e1,sc);
	be.e2=expressionSemantic(be.e2,sc);
	propErr(be.e1,be);
	propErr(be.e2,be);
	if(be.sstate==SemState.error)
		return be;
	void checkULhs(Expression lhs){
		if(auto id=cast(Identifier)lhs){
			if(!checkAssignable(id.meaning,be.loc,sc))
			   be.sstate=SemState.error;
		}else if(auto idx=cast(IndexExp)lhs){
			checkULhs(idx.e);
		}else if(auto fe=cast(FieldExp)lhs){
			checkULhs(fe.e);
		}else{
		LbadAssgnmLhs:
			sc.error(format("cannot update-assign to %s",lhs),be.e1.loc);
			be.sstate=SemState.error;
		}
	}
	checkULhs(be.e1);
	bool check(Expression ty){
		if(cast(CatAssignExp)be) return !!cast(ArrayTy)ty;
		return ty is ℝ;
	}
	if(be.sstate!=SemState.error&&be.e1.type != be.e2.type || !check(be.e1.type)){
		if(cast(CatAssignExp)be){
			sc.error(format("incompatible operand types %s and %s",be.e1.type,be.e2.type),be.loc);
		}else sc.error(format("incompatible operand types %s and %s (should be ℝ and ℝ)",be.e1.type,be.e2.type),be.loc);
		be.sstate=SemState.error;
	}
	be.type=unit;
	if(be.sstate!=SemState.error) be.sstate=SemState.completed;
	return be;
}

bool isAssignment(Expression e){
	return cast(AssignExp)e||isOpAssignExp(e);
}

Expression assignSemantic(Expression e,Scope sc)in{
	assert(isAssignment(e));
}body{
	if(auto ae=cast(AssignExp)e) return assignExpSemantic(ae,sc);
	if(isOpAssignExp(e)) return opAssignExpSemantic(cast(ABinaryExp)e,sc);
	assert(0);
}

bool isColonOrAssign(Expression e){
	return isAssignment(e)||cast(BinaryExp!(Tok!":="))e||cast(DefExp)e;
}

Expression colonOrAssignSemantic(Expression e,Scope sc)in{
	assert(isColonOrAssign(e));
}body{
	if(isAssignment(e)) return assignSemantic(e,sc);
	if(auto be=cast(BinaryExp!(Tok!":="))e) return colonAssignSemantic(be,sc);
	if(cast(DefExp)e) return e; // TODO: ok?
	assert(0);
}

Expression expectColonOrAssignSemantic(Expression e,Scope sc){
	if(auto ce=cast(CommaExp)e){
		ce.e1=expectColonOrAssignSemantic(ce.e1,sc);
		propErr(ce.e1,ce);
		ce.e2=expectColonOrAssignSemantic(ce.e2,sc);
		propErr(ce.e2,ce);
		ce.type=unit;
		if(ce.sstate!=SemState.error) ce.sstate=SemState.completed;
		return ce;
	}
	if(isColonOrAssign(e)) return colonOrAssignSemantic(e,sc);
	sc.error("expected assignment or variable declaration",e.loc);
	e.sstate=SemState.error;
	return e;
}

Expression callSemantic(CallExp ce,Scope sc){
	if(auto id=cast(Identifier)ce.e) id.calledDirectly=true;
	ce.e=expressionSemantic(ce.e,sc);
	propErr(ce.e,ce);
	ce.arg=expressionSemantic(ce.arg,sc);
	propErr(ce.arg,ce);
	if(ce.sstate==SemState.error)
		return ce;
	auto fun=ce.e;
	CallExp checkFunCall(FunTy ft){
		bool tryCall(){
			if(!ce.isSquare && ft.isSquare){
				auto nft=ft;
				if(auto id=cast(Identifier)fun){
					if(auto decl=cast(DatDecl)id.meaning){
						if(auto constructor=cast(FunctionDef)decl.body_.ascope_.lookup(decl.name,false,false)){
							if(auto cty=cast(FunTy)typeForDecl(constructor)){
								assert(ft.cod is typeTy);
								nft=productTy(ft.names,ft.dom,cty,ft.isSquare,ft.isTuple);
							}
						}
					}
				}
				if(cast(ProductTy)nft.cod){
					Expression garg;
					auto tt=nft.tryMatch(ce.arg,garg);
					if(!tt) return false;
					auto nce=new CallExp(ce.e,garg,true);
					nce.loc=ce.loc;
					auto nnce=new CallExp(nce,ce.arg,false);
					nnce.loc=ce.loc;
					nnce=cast(CallExp)callSemantic(nnce,sc);
					assert(nnce&&nnce.type == tt);
					ce=nnce;
					return true;
				}
			}
			ce.type=ft.tryApply(ce.arg,ce.isSquare);
			return !!ce.type;
		}
		if(!tryCall()){
			auto aty=ce.arg.type;
			if(ce.isSquare!=ft.isSquare)
				sc.error(text("function of type ",ft," cannot be called with arguments ",ce.isSquare?"[":"",aty,ce.isSquare?"]":""),ce.loc);
			else sc.error(format("expected argument types %s, but %s was provided",ft.dom,aty),ce.loc);
			ce.sstate=SemState.error;
		}
		return ce;
	}
	if(auto ft=cast(FunTy)fun.type){
		ce=checkFunCall(ft);
	}else if(auto at=isDataTyId(fun)){
		auto decl=at.decl;
		assert(fun.type is typeTy);
		auto constructor=cast(FunctionDef)decl.body_.ascope_.lookup(decl.name,false,false);
		auto ty=cast(FunTy)typeForDecl(constructor);
		if(ty&&decl.hasParams){
			auto nce=cast(CallExp)fun;
			assert(!!nce);
			auto subst=decl.getSubst(nce.arg);
			ty=cast(ProductTy)ty.substitute(subst);
			assert(!!ty);
		}
		if(!constructor||!ty){
			sc.error(format("no constructor for type %s",at),ce.loc);
			ce.sstate=SemState.error;
		}else{
			ce=checkFunCall(ty);
			if(ce.sstate!=SemState.error){
				auto id=new Identifier(constructor.name.name);
				id.loc=fun.loc;
				id.scope_=sc;
				id.meaning=constructor;
				id.name=constructor.getName;
				id.scope_=sc;
				id.type=ty;
				id.sstate=SemState.completed;
				if(auto fe=cast(FieldExp)fun){
					assert(fe.e.sstate==SemState.completed);
					ce.e=new FieldExp(fe.e,id);
					ce.e.type=id.type;
					ce.e.loc=fun.loc;
					ce.e.sstate=SemState.completed;
				}else ce.e=id;
			}
		}
	}else if(isBuiltIn(cast(Identifier)ce.e)){
		auto id=cast(Identifier)ce.e;
		switch(id.name){
			case "Marginal":
				ce.type=distributionTy(ce.arg.type,sc);
				break;
			case "sampleFrom":
				return handleSampleFrom(ce,sc);
			default: assert(0,text("TODO: ",id.name));
		}
	}else{
		sc.error(format("cannot call expression of type %s",fun.type),ce.loc);
		ce.sstate=SemState.error;
	}
	return ce;
}

Expression expressionSemantic(Expression expr,Scope sc){
	alias Bool=ℝ; // TODO: maybe add 𝟚 as specific boolean type?
	if(expr.sstate==SemState.completed||expr.sstate==SemState.error) return expr;
	if(expr.sstate==SemState.started){
		sc.error("cyclic dependency",expr.loc);
		expr.sstate=SemState.error;
		return expr;
	}
	assert(expr.sstate==SemState.initial);
	expr.sstate=SemState.started;
	scope(success){
		if(expr.sstate!=SemState.error){
			assert(!!expr.type);
			expr.sstate=SemState.completed;
		}
	}
	if(auto cd=cast(CompoundDecl)expr)
		return compoundDeclSemantic(cd,sc);
	if(auto ce=cast(CompoundExp)expr)
		return compoundExpSemantic(ce,sc);
	if(auto le=cast(LambdaExp)expr){
		FunctionDef nfd=le.fd;
		if(!le.fd.scope_){
			le.fd.scope_=sc;
			nfd=cast(FunctionDef)presemantic(nfd,sc);
		}else assert(le.fd.scope_ is sc);
		assert(!!nfd);
		le.fd=functionDefSemantic(nfd,sc);
		assert(!!le.fd);
		propErr(le.fd,le);
		if(le.fd.sstate==SemState.completed)
			le.type=typeForDecl(le.fd);
		if(le.fd.sstate==SemState.completed) le.sstate=SemState.completed;
		return le;
	}
	if(auto fd=cast(FunctionDef)expr){
		sc.error("function definition cannot appear within an expression",fd.loc);
		fd.sstate=SemState.error;
		return fd;
	}
	if(auto ret=cast(ReturnExp)expr){
		sc.error("return statement cannot appear within an expression",ret.loc);
		ret.sstate=SemState.error;
		return ret;
	}
	if(auto ce=cast(CallExp)expr)
		return expr=callSemantic(ce,sc);
	if(auto pl=cast(PlaceholderExp)expr){
		pl.type = ℝ;
		pl.sstate = SemState.completed;
		return pl;
	}
	if(auto id=cast(Identifier)expr){
		id.scope_=sc;
		auto meaning=id.meaning;
		if(!meaning){
			int nerr=sc.handler.nerrors; // TODO: this is a bit hacky
			meaning=sc.lookup(id,false,true);
			if(nerr!=sc.handler.nerrors){
				sc.note("looked up here",id.loc);
				id.sstate=SemState.error;
				return id;
			}
			if(!meaning){
				if(auto r=builtIn(id,sc)){
					if(!id.calledDirectly&&dutil.among(id.name,"Expectation","Marginal","sampleFrom")){
						sc.error("special operator must be called directly",id.loc);
						id.sstate=r.sstate=SemState.error;
					}
					return r;
				}
				sc.error(format("undefined identifier %s",id.name),id.loc);
				id.sstate=SemState.error;
				return id;
			}
			if(auto fd=cast(FunctionDef)meaning)
				if(auto asc=isInDataScope(fd.scope_))
					if(fd.name.name==asc.decl.name.name)
						meaning=asc.decl;
			id.meaning=meaning;
		}
		id.name=meaning.getName;
		propErr(meaning,id);
		id.type=typeForDecl(meaning);
		if(!id.type&&id.sstate!=SemState.error){
			sc.error("invalid forward reference",id.loc);
			id.sstate=SemState.error;
		}
		if(id.type != typeTy()){
			if(auto dsc=isInDataScope(id.meaning.scope_)){
				if(auto decl=sc.getDatDecl()){
					if(decl is dsc.decl){
						auto this_=new Identifier("this");
						this_.loc=id.loc;
						this_.scope_=sc;
						auto fe=new FieldExp(this_,id);
						fe.loc=id.loc;
						return expressionSemantic(fe,sc);
					}
				}
			}
		}
		if(auto vd=cast(VarDecl)id.meaning){
			if(cast(TopScope)vd.scope_){
				if(!vd.initializer||vd.initializer.sstate!=SemState.completed){
					id.sstate=SemState.error;
					return id;
				}
				return vd.initializer;
			}
		}
		return id;
	}
	if(auto fe=cast(FieldExp)expr){
		fe.e=expressionSemantic(fe.e,sc);
		propErr(fe.e,fe);
		if(fe.sstate==SemState.error)
			return fe;
		auto noMember(){
			sc.error(format("no member %s for type %s",fe.f,fe.e.type),fe.loc);
			fe.sstate=SemState.error;
			return fe;
		}
		DatDecl aggrd=null;
		if(auto aggrty=cast(AggregateTy)fe.e.type) aggrd=aggrty.decl;
		else if(auto id=cast(Identifier)fe.e.type) if(auto dat=cast(DatDecl)id.meaning) aggrd=dat;
		Expression arg=null;
		if(auto ce=cast(CallExp)fe.e.type){
			if(auto id=cast(Identifier)ce.e){
				if(auto decl=cast(DatDecl)id.meaning){
					aggrd=decl;
					arg=ce.arg;
				}
			}
		}
		if(aggrd){
			if(aggrd.body_.ascope_){
				auto meaning=aggrd.body_.ascope_.lookupHere(fe.f,false);
				if(!meaning) return noMember();
				fe.f.meaning=meaning;
				fe.f.name=meaning.getName;
				fe.f.scope_=sc;
				fe.f.type=typeForDecl(meaning);
				if(fe.f.type&&aggrd.hasParams){
					auto subst=aggrd.getSubst(arg);
					fe.f.type=fe.f.type.substitute(subst);
				}
				fe.f.sstate=SemState.completed;
				fe.type=fe.f.type;
				if(!fe.type){
					fe.sstate=SemState.error;
					fe.f.sstate=SemState.error;
				}
				return fe;
			}else return noMember();
		}else if(auto r=builtIn(fe,sc)) return r;
		else return noMember();
	}
	if(auto idx=cast(IndexExp)expr){
		idx.e=expressionSemantic(idx.e,sc);
		if(auto ft=cast(FunTy)idx.e.type){
			Expression arg;
			if(!idx.trailingComma&&idx.a.length==1) arg=idx.a[0];
			else arg=new TupleExp(idx.a);
			arg.loc=idx.loc;
			auto ce=new CallExp(idx.e,arg,true);
			ce.loc=idx.loc;
			return expr=callSemantic(ce,sc);
		}
		if(idx.e.type==typeTy)
			if(auto tty=typeSemantic(expr,sc))
				return tty;
		propErr(idx.e,idx);
		foreach(ref a;idx.a){
			a=expressionSemantic(a,sc);
			propErr(a,idx);
		}
		if(idx.sstate==SemState.error)
			return idx;
		if(auto at=cast(ArrayTy)idx.e.type){
			if(idx.a.length!=1){
				sc.error(format("only one index required to index type %s",at),idx.loc);
				idx.sstate=SemState.error;
			}else{
				if(!compatible(ℝ,idx.a[0].type)){
					sc.error(format("index should be number, not %s",idx.a[0].type),idx.loc);
					idx.sstate=SemState.error;
				}else{
					idx.type=at.next;
				}
			}
		}else if(auto tt=cast(TupleTy)idx.e.type){
			if(idx.a.length!=1){
				sc.error(format("only one index required to index type %s",tt),idx.loc);
				idx.sstate=SemState.error;
			}else{
				auto lit=cast(LiteralExp)idx.a[0];
				if(!lit||lit.lit.type!=Tok!"0"){
					sc.error(format("index for type %s should be integer constant",tt),idx.loc); // TODO: allow dynamic indexing if known to be safe?
					idx.sstate=SemState.error;
				}else{
					auto c=ℤ(lit.lit.str);
					if(c<0||c>=tt.types.length){
						sc.error(format("index for type %s is out of bounds [0..%s)",tt,tt.types.length),idx.loc);
						idx.sstate=SemState.error;
					}else{
						idx.type=tt.types[cast(size_t)c.toLong()];
					}
				}
			}
		}else{
			sc.error(format("type %s is not indexable",idx.e.type),idx.loc);
			idx.sstate=SemState.error;
		}
		return idx;
	}
	if(auto sl=cast(SliceExp)expr){
		sl.e=expressionSemantic(sl.e,sc);
		propErr(sl.e,sl);
		sl.l=expressionSemantic(sl.l,sc);
		propErr(sl.l,sl);
		sl.r=expressionSemantic(sl.r,sc);
		propErr(sl.r,sl);
		if(sl.sstate==SemState.error)
			return sl;
		if(!compatible(ℝ,sl.l.type)){
			sc.error(format("lower bound should be number, not %s",sl.l.type),sl.l.loc);
			sl.l.sstate=SemState.error;
		}
		if(!compatible(ℝ,sl.r.type)){
			sc.error(format("upper bound should be number, not %s",sl.r.type),sl.r.loc);
			sl.r.sstate=SemState.error;
		}
		if(sl.sstate==SemState.error)
			return sl;
		if(auto at=cast(ArrayTy)sl.e.type){
			sl.type=at;
		}else if(auto tt=cast(TupleTy)sl.e.type){
			auto llit=cast(LiteralExp)sl.l, rlit=cast(LiteralExp)sl.r;
			if(!llit||llit.lit.type!=Tok!"0"){
				sc.error(format("slice lower bound for type %s should be integer constant",tt),sl.loc);
				sl.sstate=SemState.error;
			}
			if(!rlit||rlit.lit.type!=Tok!"0"){
				sc.error(format("slice upper bound for type %s should be integer constant",tt),sl.loc);
				sl.sstate=SemState.error;
			}
			if(sl.sstate==SemState.error)
				return sl;
			auto lc=ℤ(llit.lit.str), rc=ℤ(rlit.lit.str);
			if(lc<0){
				sc.error(format("slice lower bound for type %s cannot be negative",tt),sl.loc);
				sl.sstate=SemState.error;
			}
			if(lc>rc){
				sc.error("slice lower bound exceeds slice upper bound",sl.loc);
				sl.sstate=SemState.error;
			}
			if(rc>tt.types.length){
				sc.error(format("slice upper bound for type %s exceeds %s",tt,tt.types.length),sl.loc);
				sl.sstate=SemState.error;
			}
			sl.type=tupleTy(tt.types[cast(size_t)lc..cast(size_t)rc]);
		}else{
			sc.error(format("type %s is not slicable",sl.e.type),sl.loc);
			sl.sstate=SemState.error;
		}
		return sl;
	}
	if(cast(CommaExp)expr){
		sc.error("nested comma expressions are disallowed",expr.loc);
		expr.sstate=SemState.error;
		return expr;
	}
	if(auto tpl=cast(TupleExp)expr){
		foreach(ref exp;tpl.e){
			exp=expressionSemantic(exp,sc);
			propErr(exp,tpl);
		}
		if(tpl.sstate!=SemState.error){
			tpl.type=tupleTy(tpl.e.map!(e=>e.type).array);
		}
		return tpl;
	}
	if(auto arr=cast(ArrayExp)expr){
		Expression t; bool tok=true;
		Expression texp;
		foreach(ref exp;arr.e){
			exp=expressionSemantic(exp,sc);
			propErr(exp,arr);
			if(t){
				if(t != exp.type && tok){
					sc.error(format("incompatible types %s and %s in array literal",t,exp.type),texp.loc);
					sc.note("incompatible entry",exp.loc);
					arr.sstate=SemState.error;
					tok=false;
				}
			}else{ t=exp.type; texp=exp; }
		}
		if(arr.e.length){
			if(arr.e[0].type) arr.type=arrayTy(arr.e[0].type);
		}else arr.type=arrayTy(ℝ); // TODO: type inference?
		return arr;
	}
	if(auto tae=cast(TypeAnnotationExp)expr){
		tae.e=expressionSemantic(tae.e,sc);
		tae.type=typeSemantic(tae.t,sc);
		propErr(tae.e,tae);
		propErr(tae.t,tae);
		if(tae.sstate==SemState.error)
			return tae;
		if(auto arr=cast(ArrayExp)tae.e){
			if(!arr.e.length)
				if(auto aty=cast(ArrayTy)tae.type)
					arr.type=aty;
		}
		if(auto ce=cast(CallExp)tae.e)
			if(auto id=cast(Identifier)ce.e){
				if(id.name=="sampleFrom"||id.name=="readCSV"&&tae.type==arrayTy(arrayTy(ℝ)))
					ce.type=tae.type;
			}
		if(tae.e.type != tae.type){
			sc.error(format("type is %s, not %s",tae.e.type,tae.type),tae.loc);
			tae.sstate=SemState.error;
		}
		return tae;
	}

	Expression handleUnary(string name,Expression e,ref Expression e1,Type t1,Type r){
		e1=expressionSemantic(e1,sc);
		propErr(e1,e);
		if(e.sstate==SemState.error)
			return e;
		if(e1.type is t1){
			e.type=r;
		}else{
			sc.error(format("incompatible type %s for %s",e1.type,name),r.loc);
			e.sstate=SemState.error;
		}
		return e;
	}
	
	Expression handleBinary(string name,Expression e,ref Expression e1,ref Expression e2,Type t1,Type t2,Type r){
		e1=expressionSemantic(e1,sc);
		e2=expressionSemantic(e2,sc);
		propErr(e1,e);
		propErr(e2,e);
		if(e.sstate==SemState.error)
			return e;
		if(e1.type == t1 && e2.type == t2){
			e.type=r;
		}else if(e1.type==typeTy&&name=="power"){
			if(auto le=cast(LiteralExp)e2){
				if(le.lit.type==Tok!"0"){
					if(!le.lit.str.canFind(".")){
						auto n=ℤ(le.lit.str);
						if(0<=n&&n<long.max)
							return tupleTy(e1.repeat(cast(size_t)n.toLong()).array);
					}
				}
			}
			sc.error("expected non-negative integer constant",e2.loc);
			e.sstate=SemState.error;
		}else{
			sc.error(format("incompatible types %s and %s for %s",e1.type,e2.type,name),e.loc);
			e.sstate=SemState.error;
		}
		return e;
	}

	if(auto ae=cast(AddExp)expr) return expr=handleBinary("addition",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(SubExp)expr) return expr=handleBinary("subtraction",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(MulExp)expr) return expr=handleBinary("multiplication",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(DivExp)expr) return expr=handleBinary("division",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(IDivExp)expr) return expr=handleBinary("integer division",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(ModExp)expr) return expr=handleBinary("modulo",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(PowExp)expr) return expr=handleBinary("power",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(BitOrExp)expr) return expr=handleBinary("bitwise or",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(BitXorExp)expr) return expr=handleBinary("bitwise xor",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(BitAndExp)expr) return expr=handleBinary("bitwise and",ae,ae.e1,ae.e2,ℝ,ℝ,ℝ);
	if(auto ae=cast(UMinusExp)expr) return expr=handleUnary("minus",ae,ae.e,ℝ,ℝ);
	if(auto ae=cast(UNotExp)expr) return expr=handleUnary("not",ae,ae.e,Bool,Bool);
	if(auto ae=cast(UBitNotExp)expr) return expr=handleUnary("bitwise not",ae,ae.e,Bool,Bool);
	if(auto ae=cast(AndExp)expr) return expr=handleBinary("conjunction",ae,ae.e1,ae.e2,Bool,Bool,Bool);
	if(auto ae=cast(OrExp)expr) return expr=handleBinary("disjunction",ae,ae.e1,ae.e2,Bool,Bool,Bool);
	if(auto ae=cast(LtExp)expr) return expr=handleBinary("'<'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(LeExp)expr) return expr=handleBinary("'≤'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(GtExp)expr) return expr=handleBinary("'>'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(GeExp)expr) return expr=handleBinary("'≥'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(EqExp)expr) return expr=handleBinary("'='",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);
	if(auto ae=cast(NeqExp)expr) return expr=handleBinary("'≠'",ae,ae.e1,ae.e2,ℝ,ℝ,Bool);

	if(auto ce=cast(CatExp)expr){
		ce.e1=expressionSemantic(ce.e1,sc);
		ce.e2=expressionSemantic(ce.e2,sc);
		propErr(ce.e1,ce);
		propErr(ce.e2,ce);
		if(ce.sstate==SemState.error)
			return ce;
		if(cast(ArrayTy)ce.e1.type && ce.e1.type == ce.e2.type){
			ce.type=ce.e1.type;
		}else{
			sc.error(format("incompatible types %s and %s for ~",ce.e1.type,ce.e2.type),ce.loc);
			ce.sstate=SemState.error;
		}
		return ce;
	}

	if(auto pr=cast(BinaryExp!(Tok!"×"))expr){
		// TODO: allow nested declarations
		expr.type=typeTy();
		auto t1=typeSemantic(pr.e1,sc);
		auto t2=typeSemantic(pr.e2,sc);
		if(!t1||!t2){
			expr.sstate=SemState.error;
			return expr;
		}
		auto l=cast(TupleTy)t1,r=cast(TupleTy)t2;
		if(l && r && !pr.e1.brackets && !pr.e2.brackets)
			return tupleTy(l.types~r.types);
		if(l&&!pr.e1.brackets) return tupleTy(l.types~t2);
		if(r&&!pr.e2.brackets) return tupleTy(t1~r.types);
		return tupleTy([t1,t2]);
	}
	if(auto ex=cast(BinaryExp!(Tok!"→"))expr){
		expr.type=typeTy();
		auto t1=typeSemantic(ex.e1,sc);
		auto t2=typeSemantic(ex.e2,sc);
		if(!t1||!t2){
			expr.sstate=SemState.error;
			return expr;
		}
		return funTy(t1,t2,false,false);
	}
	if(auto fa=cast(RawProductTy)expr){
		expr.type=typeTy();
		auto fsc=new BlockScope(sc);
		declareParameters(fa,fa.isSquare,fa.params,fsc); // parameter variables
		auto cod=typeSemantic(fa.cod,fsc);
		propErr(fa.cod,fa);
		if(fa.sstate==SemState.error) return fa;
		auto names=fa.params.map!(p=>p.getName).array;
		auto types=fa.params.map!(p=>p.vtype).array;
		assert(fa.isTuple||types.length==1);
		auto dom=fa.isTuple?tupleTy(types):types[0];
		return productTy(names,dom,cod,fa.isSquare,fa.isTuple);
	}
	if(auto ite=cast(IteExp)expr){
		ite.cond=expressionSemantic(ite.cond,sc);
		if(ite.then.s.length!=1||ite.othw&&ite.othw.s.length!=1){
			sc.error("branches of if expression must be single expressions;",ite.loc);
			ite.sstate=SemState.error;
			return ite;
		}
		Expression branchSemantic(Expression branch){
			if(auto ae=cast(AssertExp)branch){
				branch=statementSemantic(branch,sc);
				if(auto lit=cast(LiteralExp)ae.e)
					if(lit.lit.type==Tok!"0" && lit.lit.str=="0")
						branch.type=null;
			}else branch=expressionSemantic(branch,sc);
			return branch;
		}
		ite.then.s[0]=branchSemantic(ite.then.s[0]);
		propErr(ite.then.s[0],ite.then);
		if(!ite.othw){
			sc.error("missing else for if expression",ite.loc);
			ite.sstate=SemState.error;
			return ite;
		}
		ite.othw.s[0]=branchSemantic(ite.othw.s[0]);
		propErr(ite.othw.s[0],ite.othw);
		propErr(ite.cond,ite);
		propErr(ite.then,ite);
		propErr(ite.othw,ite);
		if(ite.sstate==SemState.error)
			return ite;
		if(!ite.then.s[0].type) ite.then.s[0].type = ite.othw.s[0].type;
		if(!ite.othw.s[0].type) ite.othw.s[0].type = ite.then.s[0].type;
		auto t1=ite.then.s[0].type;
		auto t2=ite.othw.s[0].type;
		if(t1 && t2 && t1 != t2){
			sc.error(format("incompatible types %s and %s for branches of if expression",t1,t2),ite.loc);
			ite.sstate=SemState.error;
		}
		ite.type=t1;
		return ite;
	}
	if(auto lit=cast(LiteralExp)expr){
		switch(lit.lit.type){
		case Tok!"0",Tok!".0":
			expr.type=ℝ;
			return expr;
		case Tok!"``":
			expr.type=stringTy;
			return expr;
		default: break; // TODO
		}
	}
	if(expr.kind=="expression") sc.error("unsupported",expr.loc);
	else sc.error(expr.kind~" cannot appear within an expression",expr.loc);
	expr.sstate=SemState.error;
	return expr;
}
bool setFtype(FunctionDef fd){
	string[] pn;
	Expression[] pty;
	foreach(p;fd.params){
		if(!p.vtype){
			assert(fd.sstate==SemState.error);
			return false;
		}
		pn~=p.getName;
		pty~=p.vtype;
	}
	assert(fd.isTuple||pty.length==1);
	auto pt=fd.isTuple?tupleTy(pty):pty[0];
	if(fd.ret){
		if(!fd.ftype){
			fd.ftype=productTy(pn,pt,fd.ret,fd.isSquare,fd.isTuple);
			assert(fd.retNames==[]);
		}
		if(!fd.retNames) fd.retNames = new string[](fd.numReturns);
	}
	return true;
}
FunctionDef functionDefSemantic(FunctionDef fd,Scope sc){
	if(!fd.scope_) fd=cast(FunctionDef)presemantic(fd,sc);
	auto fsc=fd.fscope_;
	assert(!!fsc,text(fd));
	auto bdy=compoundExpSemantic(fd.body_,fsc);
	assert(!!bdy);
	fd.body_=bdy;
	fd.type=unit;
	propErr(bdy,fd);
	if(!definitelyReturns(fd)){
		if(!fd.ret || fd.ret == unit){
			auto tpl=new TupleExp([]);
			tpl.loc=fd.loc;
			auto rete=new ReturnExp(tpl);
			rete.loc=fd.loc;
			fd.body_.s~=returnExpSemantic(rete,fd.body_.blscope_);
		}else{
			sc.error("control flow might reach end of function (add return or assert(0) statement)",fd.loc);
			fd.sstate=SemState.error;
		}
	}else if(!fd.ret) fd.ret=unit;
	setFtype(fd);
	foreach(ref n;fd.retNames){
		if(n is null) n="r";
		else n=n.stripRight('\'');
	}
	void[0][string] vars;
	foreach(p;fd.params) vars[p.getName]=[];
	int[string] counts1,counts2;
	foreach(n;fd.retNames)
		++counts1[n];
	foreach(ref n;fd.retNames){
		if(counts1[n]>1)
			n~=lowNum(++counts2[n]);
		while(n in vars) n~="'";
		vars[n]=[];
	}
	if(fd.sstate!=SemState.error)
		fd.sstate=SemState.completed;
	return fd;
}

DatDecl datDeclSemantic(DatDecl dat,Scope sc){
	bool success=true;
	if(!dat.dscope_) presemantic(dat,sc);
	auto bdy=compoundDeclSemantic(dat.body_,dat.dscope_);
	assert(!!bdy);
	dat.body_=bdy;
	dat.type=unit;
	return dat;
}

Expression determineType(ref Expression e,Scope sc){
	if(auto le=cast(LambdaExp)e){
		assert(!!le.fd);
		if(!le.fd.scope_){
			le.fd.scope_=sc;
			le.fd=cast(FunctionDef)presemantic(le.fd,sc);
			assert(!!le.fd);
		}
		if(auto ty=le.fd.ftype)
			return ty;
	}
	e=expressionSemantic(e,sc);
	return e.type;
}

ReturnExp returnExpSemantic(ReturnExp ret,Scope sc){
	if(ret.sstate==SemState.completed) return ret;
	auto fd=sc.getFunction();
	if(!fd){
		sc.error("return statement must be within function",ret.loc);
		ret.sstate=SemState.error;
		return ret;
	}
	auto ty=determineType(ret.e,sc);
	if(!fd.rret && !fd.ret) fd.ret=ty;
	setFtype(fd);
	if(ret.e.sstate!=SemState.completed)
		ret.e=expressionSemantic(ret.e,sc);
	if(cast(CommaExp)ret.e){
		sc.error("use parentheses for multiple return values",ret.e.loc);
		ret.sstate=SemState.error;
	}
	propErr(ret.e,ret);
	if(ret.sstate==SemState.error)
		return ret;
	if(!compatible(fd.ret,ret.e.type)){
		sc.error(format("%s is incompatible with return type %s",ret.e.type,fd.ret),ret.e.loc);
		ret.sstate=SemState.error;
		return ret;
	}
	ret.type=unit;
	Expression[] returns;
	if(auto tpl=cast(TupleExp)ret.e) returns=tpl.e;
	else returns = [ret.e];
	static string getName(Expression e){
		string candidate(Expression e,bool allowNum=false){
			if(auto id=cast(Identifier)e) return id.name;
			if(auto fe=cast(FieldExp)e) return fe.f.name;
			if(auto ie=cast(IndexExp)e){
				auto idx=candidate(ie.a[0],true);
				if(!idx) idx="i";
				auto low=toLow(idx);
				if(!low) low="_"~idx;
				auto a=candidate(ie.e);
				if(!a) return null;
				return a~low;
			}
			if(allowNum){
				if(auto le=cast(LiteralExp)e){
					if(le.lit.type==Tok!"0")
						return le.lit.str;
				}
			}
			return null;
		}
		auto r=candidate(e);
		if(dutil.among(r.stripRight('\''),"delta","sum","abs","log","lim","val","⊥","case","e","π")) return null;
		return r;
	}
	if(returns.length==fd.retNames.length){
		foreach(i,e;returns)
			if(auto n=getName(e)) fd.retNames[i]=n;
	}else if(returns.length==1){
		if(auto name=getName(returns[0]))
			foreach(ref n;fd.retNames) n=name;
	}
	return ret;
}


Expression typeSemantic(Expression expr,Scope sc)in{assert(!!expr&&!!sc);}body{
	if(expr.type==typeTy) return expr;
	if(auto lit=cast(LiteralExp)expr){
		lit.type=typeTy;
		if(lit.lit.type==Tok!"0"){
			if(lit.lit.str=="1")
				return unit;
		}
	}
	auto at=cast(IndexExp)expr;
	if(at&&at.a==[]){
		expr.type=typeTy;
		auto next=typeSemantic(at.e,sc);
		propErr(at.e,expr);
		if(!next) return null;
		return arrayTy(next);
	}
	auto e=expressionSemantic(expr,sc);
	if(!e) return null;
	if(e.type==typeTy) return e;
	if(expr.sstate!=SemState.error){
		auto id=cast(Identifier)expr;
		if(id&&id.meaning){
			auto decl=id.meaning;
			sc.error(format("%s %s is not a type",decl.kind,decl.name),id.loc);
			sc.note("declared here",decl.loc);
		}else sc.error("not a type",expr.loc);
		expr.sstate=SemState.error;
	}
	return null;
 }

Expression typeForDecl(Declaration decl){
	if(auto dat=cast(DatDecl)decl){
		if(!dat.dtype&&dat.scope_) dat=cast(DatDecl)presemantic(dat,dat.scope_);
		assert(cast(AggregateTy)dat.dtype);
		if(!dat.hasParams) return typeTy;
		foreach(p;dat.params) if(!p.vtype) return unit; // TODO: ok?
		assert(dat.isTuple||dat.params.length==1);
		auto pt=dat.isTuple?tupleTy(dat.params.map!(p=>p.vtype).array):dat.params[0].vtype;
		return productTy(dat.params.map!(p=>p.getName).array,pt,typeTy,true,dat.isTuple);
	}
	if(auto vd=cast(VarDecl)decl){
		return vd.vtype;
	}
	if(auto fd=cast(FunctionDef)decl){
		if(!fd.ftype&&fd.scope_) fd=functionDefSemantic(fd,fd.scope_);
		assert(!!fd);
		return fd.ftype;
	}
	return unit; // TODO
}

bool definitelyReturns(FunctionDef fd){
	bool doIt(Expression e){
		if(auto ret=cast(ReturnExp)e)
			return true;
		bool isZero(Expression e){
			if(auto le=cast(LiteralExp)e)
				if(le.lit.type==Tok!"0")
					if(le.lit.str=="0")
						return true;
			return false;
		}
		alias isFalse=isZero;
		bool isTrue(Expression e){
			if(auto le=cast(LiteralExp)e)
				if(le.lit.type==Tok!"0")
					return le.lit.str!="0";
			return false;
		}
		bool isPositive(Expression e){
			if(isZero(e)) return false;
			if(auto le=cast(LiteralExp)e)
				if(le.lit.type==Tok!"0")
					return le.lit.str[0]!='-';
			return false;
		}
		if(auto ae=cast(AssertExp)e)
			return isFalse(ae.e);
		if(auto oe=cast(ObserveExp)e)
			return isFalse(oe.e);
		if(auto ce=cast(CompoundExp)e)
			return ce.s.any!(x=>doIt(x));
		if(auto ite=cast(IteExp)e)
			return doIt(ite.then) && doIt(ite.othw);
		if(auto fe=cast(ForExp)e){
			auto lle=cast(LiteralExp)fe.left;
			auto rle=cast(LiteralExp)fe.right;
			if(lle && rle && lle.lit.type==Tok!"0" && rle.lit.type==Tok!"0"){
				ℤ l=ℤ(lle.lit.str), r=ℤ(rle.lit.str);
				l+=cast(long)fe.leftExclusive;
				r-=cast(long)fe.rightExclusive;
				return l<=r && doIt(fe.bdy);
			}
			return false;
		}
		if(auto we=cast(WhileExp)e)
			return isTrue(we.cond) && doIt(we.bdy);
		if(auto re=cast(RepeatExp)e)
			return isPositive(re.num);
		return false;
	}
	return doIt(fd.body_);
}


import dexpr;
struct VarMapping{
	DNVar orig;
	DNVar tmp;
}
struct SampleFromInfo{
	bool error;
	VarMapping[] retVars;
	DNVar[] paramVars;
	DExpr newDist;	
}

import distrib; // TODO: separate concerns properly, move the relevant parts back to analysis.d
SampleFromInfo analyzeSampleFrom(CallExp ce,ErrorHandler err,Distribution dist=null){ // TODO: support for non-real-valued distributions
	Expression[] args;
	if(auto tpl=cast(TupleExp)ce.arg) args=tpl.e;
	else args=[ce.arg];
	if(args.length==0){
		err.error("expected arguments to sampleFrom",ce.loc);
		return SampleFromInfo(true);
	}
	auto literal=cast(LiteralExp)args[0];
	if(!literal||literal.lit.type!=Tok!"``"){
		err.error("first argument to sampleFrom must be string literal",args[0].loc);
		return SampleFromInfo(true);
	}
	VarMapping[] retVars;
	DNVar[] paramVars;
	DExpr newDist;
	import hashtable;
	HSet!(string,(a,b)=>a==b,a=>typeid(string).getHash(&a)) names;
	try{
		import dparse;
		auto parser=DParser(literal.lit.str);
		parser.skipWhitespace();
		parser.expect('(');
		for(bool seen=false;parser.cur()!=')';){
			parser.skipWhitespace();
			if(parser.cur()==';'){
				seen=true;
				parser.next();
				continue;
			}
			auto orig=cast(DNVar)parser.parseDVar();
			if(!orig) throw new Exception("TODO");
			if(orig.name in names){
				err.error(text("multiple variables of name \"",orig.name,"\""),args[0].loc);
				return SampleFromInfo(true);
			}
			if(!seen){
				auto tmp=dist?dist.getTmpVar("__tmp"~orig.name):null; // TODO: this is a hack
				retVars~=VarMapping(orig,tmp);
			}else paramVars~=orig;
			parser.skipWhitespace();
			if(!";)"[seen..$].canFind(parser.cur())) parser.expect(',');
		}
		parser.next();
		parser.skipWhitespace();
		if(parser.cur()=='⇒') parser.next();
		else{ parser.expect('='); parser.expect('>'); }
		parser.skipWhitespace();
		newDist=parser.parseDExpr();
	}catch(Exception e){
		err.error(e.msg,args[0].loc);
		return SampleFromInfo(true);
	}
	if(dist){
		foreach(var;retVars){
			if(!newDist.hasFreeVar(var.orig)){
				err.error(text("pdf must depend on variable ",var.orig.name,")"),args[0].loc);
				return SampleFromInfo(true);
			}
		}
		newDist=newDist.substituteAll(retVars.map!(x=>cast(DVar)x.orig).array,retVars.map!(x=>cast(DExpr)x.tmp).array);
	}
	if(args.length!=1+paramVars.length){
		err.error(text("expected ",paramVars.length," additional arguments to sampleFrom"),ce.loc);
		return SampleFromInfo(true);
	}
	return SampleFromInfo(false,retVars,paramVars,newDist);
}

Expression handleSampleFrom(CallExp ce,Scope sc){
	auto info=analyzeSampleFrom(ce,sc.handler);
	if(info.error){
		ce.sstate=SemState.error;
	}else{
		 // TODO: this special casing is not very nice:
		ce.type=info.retVars.length==1?ℝ:tupleTy((cast(Expression)ℝ).repeat(info.retVars.length).array);
	}
	return ce;
}
