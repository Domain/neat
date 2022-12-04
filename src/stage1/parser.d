module parser;

import boilerplate;
import linenr;
import std.algorithm;
import std.conv;
import std.format;
import std.range;
import std.string;
import std.uni;

class Parser
{
    string[] stack;

    invariant (!this.stack.empty);

    size_t level;

    invariant (this.level <= this.stack.length);

    LineNumberRegistry lineNumbers;

    this(string filename, string text)
    {
        this.stack ~= text;
        this.lineNumbers = new LineNumberRegistry;
        this.lineNumbers.register(filename, text);
    }

    @property ref string text()
    {
        return this.stack[this.level];
    }

    void begin()
    {
        if (this.level == this.stack.length - 1)
        {
            this.stack ~= this.text;
        }
        else
        {
            this.stack[this.level + 1] = this.text;
        }
        this.level++;
    }

    void commit()
    in (this.level > 0)
    {
        this.stack[this.level - 1] = text;
        this.level--;
    }

    void revert()
    in (this.level > 0)
    {
        this.level--;
    }

    bool accept(string match)
    {
        begin;

        strip;
        if (this.text.startsWith(match))
        {
            this.text = this.text.drop(match.length);
            commit;
            return true;
        }
        revert;
        return false;
    }

    void expect(string match)
    {
        if (!accept(match))
        {
            fail(format!"'%s' expected."(match));
        }
    }

    bool eof()
    {
        begin;
        strip;
        if (this.text.empty)
        {
            commit;
            return true;
        }
        revert;
        return false;
    }

    void assert_(T)(T test, string msg)
    {
        assert(test, format!"at %s: %s"(this.lineNumbers.at(this.text), msg));
    }

    void fail(string msg)
    {
        assert(false, format!"at %s: %s"(this.lineNumbers.at(this.text), msg));
    }

    Loc loc()
    {
        return Loc(this.lineNumbers, this.text);
    }

    void strip()
    {
        while (true)
        {
            this.text = this.text.strip;
            if (this.text.startsWith("//"))
            {
                this.text = this.text.find("\n");
                continue;
            }
            if (!this.text.startsWith("/*")) break;
            this.text = this.text["/*".length .. $];
            int commentLevel = 1;
            while (commentLevel > 0)
            {
                import std.algorithm : find;

                auto more = this.text.find("/*"), less = this.text.find("*/");

                if (more.empty && less.empty) fail("comment spans end of file");
                if (!less.empty && less.length > more.length)
                {
                    this.text = less["*/".length .. $];
                    commentLevel --;
                }
                if (!more.empty && more.length > less.length)
                {
                    this.text = more["/*".length .. $];
                    commentLevel ++;
                }
            }
        }
    }
}

struct Loc
{
    LineNumberRegistry lineNumbers;

    string text;

    void fail(string msg) {
        import core.stdc.stdlib : exit;
        import std.stdio : writefln;

        writefln!"at %s: %s"(this.lineNumbers.at(this.text), msg);
        exit(1);
    }

    void assert_(T)(T flag, lazy string text) {
        if (!flag) fail(text);
    }

    mixin(GenerateThis);
}

enum ParserGuard(string file = __FILE__, size_t line = __LINE__) = format!q{
    const _guard = parser.level;
    scope(success) {
        import core.exception : AssertError;
        import std.format : format;

        if (parser.level != _guard) {
            const msg = format!"parser level expected %%s, but got %%s"(_guard, parser.level);
            throw new AssertError(msg, `%s`, %s);
        }
    }
}(file, line);

bool parseNumber(ref Parser parser, out int i)
{
    with (parser)
    {
        begin;
        bool negative = false;
        if (accept("-"))
        {
            negative = true;
        }
        strip;
        if (text.empty || !text.front.isNumber)
        {
            revert;
            return false;
        }
        string number;
        while (!text.empty && text.front.isNumber)
        {
            number ~= text.front;
            text.popFront;
        }
        commit;
        i = number.to!int;
        if (negative) i = -i;
        return true;
    }
}

string parseIdentifier(ref Parser parser, string additionalCharacters = "")
{
    with (parser)
    {
        begin;
        strip;
        if (text.empty || (!text.front.isAlpha && text.front != '_' && !additionalCharacters.canFind(text.front)))
        {
            revert;
            return null;
        }
        string identifier;
        while (!text.empty && (text.front.isAlphaNum || text.front == '_' || additionalCharacters.canFind(text.front)))
        {
            identifier ~= text.front;
            text.popFront;
        }
        commit;
        return identifier;
    }
}


bool acceptIdentifier(ref Parser parser, string identifier)
{
    with (parser)
    {
        begin;
        if (parser.parseIdentifier != identifier)
        {
            revert;
            return false;
        }
        commit;
        return true;
    }
}