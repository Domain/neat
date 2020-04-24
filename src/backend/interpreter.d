module backend.interpreter;

import backend_deps;
import backend.backend;
import backend.value;
import boilerplate;
import std.algorithm;
import std.array;
import std.format;

class IpBackend : Backend
{
    override IpBackendModule createModule() { return new IpBackendModule; }
}

class IpBackendType : BackendType
{
}

class IntType : IpBackendType
{
}

class VoidType : IpBackendType
{
}

class StructType : IpBackendType
{
    IpBackendType[] types;

    mixin(GenerateThis);
}

class BasicBlock
{
    int regBase;

    @(This.Init!false)
    bool finished;

    @(This.Init!null)
    Instr[] instrs;

    private int append(Instr instr)
    {
        assert(!this.finished);
        if (instr.kind.isBlockFinisher) this.finished = true;

        this.instrs ~= instr;
        return cast(int) (this.instrs.length - 1 + this.regBase);
    }

    mixin(GenerateThis);
}

struct Instr
{
    enum Kind
    {
        Call,
        Arg,
        Literal,
        Alloca,
        FieldOffset,
        Load,
        Store,
        // block finishers
        Return,
        Branch,
        TestBranch,
    }
    Kind kind;
    union
    {
        static struct Call
        {
            string name;
            Reg[] args;
        }
        static struct Return
        {
            Reg reg;
        }
        static struct Arg
        {
            int index;
        }
        static struct Literal
        {
            Value value;
        }
        static struct Branch
        {
            int targetBlock;
        }
        static struct TestBranch
        {
            Reg test;
            int thenBlock;
            int elseBlock;
        }
        static struct Alloca
        {
            IpBackendType type;
        }
        static struct FieldOffset
        {
            StructType structType;
            Reg base;
            int member;
        }
        static struct Load
        {
            IpBackendType targetType;
            Reg target;
        }
        static struct Store
        {
            IpBackendType targetType;
            Reg target;
            Reg value;
        }
        Call call;
        Return return_;
        Arg arg;
        Literal literal;
        Branch branch;
        TestBranch testBranch;
        Alloca alloca;
        FieldOffset fieldOffset;
        Load load;
        Store store;
    }
}

private bool isBlockFinisher(Instr.Kind kind)
{
    with (Instr.Kind) final switch (kind)
    {
        case Return:
        case Branch:
        case TestBranch:
            return true;
        case Call:
        case Arg:
        case Literal:
        case Alloca:
        case FieldOffset:
        case Load:
        case Store:
            return false;
    }
}

class IpBackendFunction : BackendFunction
{
    string name;

    IpBackendType retType;

    IpBackendType[] argTypes;

    @(This.Init!null)
    BasicBlock[] blocks;

    private BasicBlock block()
    {
        if (this.blocks.empty || this.blocks.back.finished)
        {
            int regBase = this.blocks.empty
                ? 0
                : (this.blocks.back.regBase + cast(int) this.blocks.back.instrs.length);

            this.blocks ~= new BasicBlock(regBase);
        }

        return this.blocks[$ - 1];
    }

    override int blockIndex()
    {
        block;
        return cast(int) (this.blocks.length - 1);
    }

    override int arg(int index)
    {
        auto instr = Instr(Instr.Kind.Arg);

        instr.arg.index = index;
        return block.append(instr);
    }

    override int literal(int value)
    {
        auto instr = Instr(Instr.Kind.Literal);

        instr.literal.value = Value.make!int(value);
        return block.append(instr);
    }

    override int call(string name, Reg[] args)
    {
        auto instr = Instr(Instr.Kind.Call);

        instr.call.name = name;
        instr.call.args = args.dup;
        return block.append(instr);
    }

    override void ret(Reg reg)
    {
        auto instr = Instr(Instr.Kind.Return);

        instr.return_.reg = reg;
        block.append(instr);
    }

    override int alloca(BackendType type)
    in (cast(IpBackendType) type)
    {
        auto instr = Instr(Instr.Kind.Alloca);

        instr.alloca.type = cast(IpBackendType) type;
        return block.append(instr);
    }

    override Reg fieldOffset(BackendType structType, Reg structBase, int member)
    in (cast(StructType) structType)
    {
        auto instr = Instr(Instr.Kind.FieldOffset);

        instr.fieldOffset.structType = cast(StructType) structType;
        instr.fieldOffset.base = structBase;
        instr.fieldOffset.member = member;

        return block.append(instr);
    }

    override void store(BackendType targetType, Reg target, Reg value)
    in (cast(IpBackendType) targetType)
    {
        auto instr = Instr(Instr.Kind.Store);

        instr.store.targetType = cast(IpBackendType) targetType;
        instr.store.target = target;
        instr.store.value = value;

        block.append(instr);
    }

    override Reg load(BackendType targetType, Reg target)
    in (cast(IpBackendType) targetType)
    {
        auto instr = Instr(Instr.Kind.Load);

        instr.load.targetType = cast(IpBackendType) targetType;
        instr.load.target = target;

        return block.append(instr);
    }

    override TestBranchRecord testBranch(Reg test)
    {
        auto instr = Instr(Instr.Kind.TestBranch);

        instr.testBranch.test = test;

        auto block = block;

        block.append(instr);

        assert(block.finished);

        return new class TestBranchRecord {
            override void resolveThen(int index)
            {
                block.instrs[$ - 1].testBranch.thenBlock = index;
            }
            override void resolveElse(int index)
            {
                block.instrs[$ - 1].testBranch.elseBlock = index;
            }
        };
    }

    override BranchRecord branch()
    {
        auto instr = Instr(Instr.Kind.Branch);
        auto block = block;

        block.append(instr);

        assert(block.finished);

        return new class BranchRecord {
            override void resolve(int index)
            {
                block.instrs[$ - 1].branch.targetBlock = index;
            }
        };
    }

    int regCount()
    {
        return this.blocks.empty
            ? 0
            : this.blocks[$ - 1].regBase + cast(int) this.blocks[$ - 1].instrs.length;
    }

    mixin(GenerateThis);
}

Value getInitValue(IpBackendType type)
{
    if (cast(IntType) type)
    {
        return Value.make!int(0);
    }
    if (auto strct = cast(StructType) type)
    {
        return Value.makeStruct(strct.types.map!getInitValue.array);
    }
    assert(false, "what is init for " ~ type.toString);
}

struct ArrayAllocator(T)
{
    static assert(T.sizeof >= (T*).sizeof);

    static T*[] pointers = null;

    static T[] allocate(int length)
    {
        if (length == 0) return null;

        int slot = findMsb(length - 1);
        while (slot >= this.pointers.length) this.pointers ~= null;
        if (this.pointers[slot]) {
            auto ret = this.pointers[slot][0 .. length];
            this.pointers[slot] = *cast(T**) this.pointers[slot];
            return ret;
        }
        assert(length <= (1 << slot));
        return (new T[1 << slot])[0 .. length];
    }

    static void free(T[] array)
    {
        if (array.empty) return;

        int slot = findMsb(cast(int) array.length);
        *cast(T**) array.ptr = this.pointers[slot];
        this.pointers[slot] = array.ptr;
    }
}

private int findMsb(int size)
{
    int bit_ = 0;
    while (size) {
        bit_ ++;
        size >>= 1;
    }
    return bit_;
}

unittest
{
    foreach (i, v; [0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5])
        assert(findMsb(cast(int) i) == v);
}

class IpBackendModule : BackendModule
{
    alias Callable = Value delegate(Value[]);
    Callable[string] callbacks;
    IpBackendFunction[string] functions;

    void defineCallback(string name, Callable call)
    in (name !in callbacks && name !in functions)
    {
        callbacks[name] = call;
    }

    Value call(string name, Value[] args...)
    in (name in this.functions || name in this.callbacks, format!"%s not found"(name))
    {
        if (name in this.callbacks)
        {
            return this.callbacks[name](args);
        }
        auto fun = this.functions[name];
        auto regs = ArrayAllocator!Value.allocate(fun.regCount);
        auto allocaRegion = new MemoryRegion;

        scope(success)
        {
            ArrayAllocator!Value.free(regs);
        }

        int block = 0;
        while (true)
        {
            assert(block >= 0 && block < fun.blocks.length);

            foreach (i, instr; fun.blocks[block].instrs)
            {
                const lastInstr = i == fun.blocks[block].instrs.length - 1;

                int reg = fun.blocks[block].regBase + cast(int) i;

                with (Instr.Kind)
                {
                    final switch (instr.kind)
                    {
                        case Call:
                            assert(!lastInstr);
                            Value[] callArgs = instr.call.args.map!(reg => regs[reg]).array;
                            regs[reg] = call(instr.call.name, callArgs);
                            break;
                        case Return:
                            assert(lastInstr);
                            return regs[instr.return_.reg];
                            break;
                        case Arg:
                            assert(!lastInstr);
                            regs[reg] = args[instr.arg.index];
                            break;
                        case Literal:
                            assert(!lastInstr);
                            regs[reg] = instr.literal.value;
                            break;
                        case Branch:
                            assert(lastInstr);
                            block = instr.branch.targetBlock;
                            break;
                        case TestBranch:
                            assert(lastInstr);
                            Value testValue = regs[instr.testBranch.test];
                            if (testValue.as!int) {
                                block = instr.testBranch.thenBlock;
                            } else {
                                block = instr.testBranch.elseBlock;
                            }
                            break;
                        case Alloca:
                            auto value = getInitValue(instr.alloca.type);

                            regs[reg] = allocaRegion.allocate(value);
                            break;
                        case FieldOffset:
                            // TODO validate type
                            auto base = regs[instr.fieldOffset.base];

                            assert(base.kind == Value.Kind.Pointer);
                            regs[reg] = base.asPointer.offset(instr.fieldOffset.member);
                            break;
                        case Load:
                            // TODO validate type
                            auto target = regs[instr.load.target];

                            assert(target.kind == Value.Kind.Pointer);
                            regs[reg] = target.asPointer.load;
                            break;
                        case Store:
                            auto target = regs[instr.store.target];

                            assert(target.kind == Value.Kind.Pointer);
                            target.asPointer.store(regs[instr.store.value]);
                            regs[reg] = Value.make!void;
                            break;
                    }
                }
            }
        }
    }

    override IntType intType() { return new IntType; }

    override IpBackendType voidType() { return new VoidType; }

    override IpBackendType structType(BackendType[] types)
    in (types.all!(a => cast(IpBackendType) a))
    {
        return new StructType(types.map!(a => cast(IpBackendType) a).array);
    }

    override IpBackendFunction define(string name, BackendType ret, BackendType[] args)
    in (name !in callbacks && name !in functions)
    in (cast(IpBackendType) ret)
    in (args.all!(a => cast(IpBackendType) a))
    {
        auto fun = new IpBackendFunction(name, cast(IpBackendType) ret, args.map!(a => cast(IpBackendType) a).array);

        this.functions[name] = fun;
        return fun;
    }
}

unittest
{
    auto mod = new IpBackendModule;
    mod.defineCallback("int_mul", delegate Value(Value[] args)
    in (args.length == 2)
    {
        return Value.make!int(args[0].as!int * args[1].as!int);
    });
    auto square = mod.define("square", mod.intType, [mod.intType, mod.intType]);
    with (square) {
        auto arg0 = arg(0);
        auto reg = call("int_mul", [arg0, arg0]);

        ret(reg);
    }

    mod.call("square", Value.make!int(5)).should.equal(Value.make!int(25));
}

/+
    int ack(int m, int n) {
        if (m == 0) { return n + 1; }
        if (n == 0) { return ack(m - 1, 1); }
        return ack(m - 1, ack(m, n - 1));
    }
+/
unittest
{
    auto mod = new IpBackendModule;
    mod.defineCallback("int_add", delegate Value(Value[] args)
    in (args.length == 2)
    {
        return Value.make!int(args[0].as!int + args[1].as!int);
    });
    mod.defineCallback("int_sub", delegate Value(Value[] args)
    in (args.length == 2)
    {
        return Value.make!int(args[0].as!int - args[1].as!int);
    });
    mod.defineCallback("int_eq", delegate Value(Value[] args)
    in (args.length == 2)
    {
        return Value.make!int(args[0].as!int == args[1].as!int);
    });

    auto ack = mod.define("ack", mod.intType, [mod.intType, mod.intType]);

    with (ack)
    {
        auto m = arg(0);
        auto n = arg(1);
        auto zero = literal(0);
        auto one = literal(1);

        auto if1_test_reg = call("int_eq", [m, zero]);
        auto if1_test_jumprecord = testBranch(if1_test_reg);

        if1_test_jumprecord.resolveThen(blockIndex);
        auto add = call("int_add", [n, one]);
        ret(add);

        if1_test_jumprecord.resolveElse(blockIndex);
        auto if2_test_reg = call("int_eq", [n, zero]);
        auto if2_test_jumprecord = testBranch(if2_test_reg);

        if2_test_jumprecord.resolveThen(blockIndex);
        auto sub = call("int_sub", [m, one]);
        auto ackrec = call("ack", [sub, one]);

        ret(ackrec);

        if2_test_jumprecord.resolveElse(blockIndex);
        auto n1 = call("int_sub", [n, one]);
        auto ackrec1 = call("ack", [m, n1]);
        auto m1 = call("int_sub", [m, one]);
        auto ackrec2 = call("ack", [m1, ackrec1]);
        ret(ackrec2);
    }

    mod.call("ack", Value.make!int(3), Value.make!int(8)).should.equal(Value.make!int(2045));
}

unittest
{
    /*
     * int square(int i) { int k = i; int l = k * k; return l; }
     */
    auto mod = new IpBackendModule;
    mod.defineCallback("int_mul", delegate Value(Value[] args)
    in (args.length == 2)
    {
        return Value.make!int(args[0].as!int * args[1].as!int);
    });
    auto square = mod.define("square", mod.intType, [mod.intType, mod.intType]);
    auto stackframeType = mod.structType([mod.intType, mod.intType]);
    with (square) {
        auto stackframe = alloca(stackframeType);
        auto arg0 = arg(0);
        auto var = fieldOffset(stackframeType, stackframe, 0);
        store(mod.intType, var, arg0);
        auto varload = load(mod.intType, var);
        auto reg = call("int_mul", [varload, varload]);
        auto retvar = fieldOffset(stackframeType, stackframe, 0);
        store(mod.intType, retvar, reg);

        auto retreg = load(mod.intType, retvar);
        ret(retreg);
    }

    mod.call("square", Value.make!int(5)).should.equal(Value.make!int(25));
}