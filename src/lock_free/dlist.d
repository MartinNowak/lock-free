module lock_free.dlist;

import std.algorithm, std.concurrency, std.conv, std.stdio;
import core.atomic, core.thread;

////////////////////////////////////////////////////////////////////////////////
// lock-free implementation
////////////////////////////////////////////////////////////////////////////////

shared class AtomicDList(T)
{
    shared struct Node
    {
        private Node* _prev;
        private Node* _next;
        private T _payload;

        this(shared T payload) shared
        {
            this._payload = payload;
        }

        @property shared(Node)* prev()
        {
            return clearlsb(this._prev);
        }

        @property shared(Node)* next()
        {
            return clearlsb(this._next);
        }
    }

    private Node _head;
    private Node _tail;
    enum bottom = clearlsb(cast(shared(Node)*)0xdeadbeafdeadbeaf);
    //  enum bottom = null;

    this ()
    {
        this._head._prev = bottom;
        this._head._next = &this._tail;
        this._tail._prev = &this._head;
        this._tail._next = bottom;
    }

    bool empty()
    {
        return this._head._next == &this._tail;
    }

    void pushFront(shared T value)
    {
        auto newNode = new shared(Node)(value);
        auto prev = &this._head;
        typeof(prev) next;
        do
        {
            next = prev.next;
            newNode._prev = prev;
            newNode._next = next;
        } while (!cas(&prev._next, next, newNode));
        linkPrev(cast(shared)newNode, next);
    }

    void pushBack(shared T value)
    {
        auto newNode = new shared(Node)(value);
        auto next = &this._tail;
        auto prev = next._prev;
        while (true)
        {
            newNode._prev = prev;
            newNode._next = next;
            if (cas(&prev._next, next, cast(shared)newNode))
                break;
            if (correctPrev(prev, next))
                prev = clearlsb(next._prev);
        }
        linkPrev(newNode, next);
    }

    @property shared(T)* popFront()
    {
        auto prev = &this._head;
        while (true) {
            auto node = prev._next;
            if (node == &this._tail)
                return null;

            auto next = node._next;
            if (haslsb(next))
            {
                setMark(&node._prev);
                cas(&prev._next, node, clearlsb(next));
                continue;
            }

            if (cas(&node._next, next, setlsb(next)))
            {
                correctPrev(prev, next);
                return &node._payload;
            }
        }
    }

    @property shared(T)* popBack()
    {
        auto next = &this._tail;
        auto node = next._prev;
        while (true)
        {
            if (node._next != next)
            {
                if (correctPrev(node, next))
                    node = clearlsb(next._prev);
                continue;
            }
            if (node == &this._head)
                return null;

            if (cas(&node._next, next, setlsb(next)))
            {
                correctPrev(clearlsb(node._prev), next);
                return &node._payload;
            }
        }
    }

    bool next(ref shared(Node)* cursor)
    {
        assert(!haslsb(cursor));
        while (true)
        {
            if (cursor == &this._tail)
                return false;
            auto next = clearlsb(cursor._next);
            auto d = haslsb(next._next);
            if (d && cursor._next != setlsb(next))
            {
                setMark(&next._prev);
                cas(&cursor._next, next, clearlsb(next._next));
                continue;
            }
            cursor = next;
            if (!d && next != &this._tail)
                assert(next != bottom);
            return true;
        }
    }

    bool prev(ref shared(Node)* cursor)
    {
        assert(!haslsb(cursor));
        while (true)
        {
            if (cursor == &this._head)
                return false;

            auto prev = clearlsb(cursor._prev);
            if (prev._next == cursor && !haslsb(cursor._next))
            {
                cursor = prev;
                if (prev != &this._head)
                    return true;
            }
            else if (haslsb(cursor._next))
            {
                this.next(cursor);
            }
            else
            {
                correctPrev(prev, cursor);
            }
        }
    }

    shared(T)* deleteNode(ref shared(Node)* cursor)
    {
        assert(!haslsb(cursor));
        auto node = cursor;
        if (node == &this._head || node == &this._tail)
            return null;

        while (true)
        {
            auto next = cursor._next;
            if (haslsb(next))
            {
                return null;
            }
            if (cas(&node._next, next, setlsb(next)))
            {
                shared(Node)* prev;
                while (true)
                {
                    prev = node._prev;
                    if (haslsb(prev) || cas(&node._prev, prev, setlsb(prev)))
                        break;
                }

                assert(!haslsb(next));
                correctPrev(clearlsb(prev), next);
                return &node._payload;
            }
        }
    }

    void insertBefore(ref shared(Node)* in_cursor, shared T value)
    {
        assert(!haslsb(in_cursor));
        auto cursor = in_cursor;

        if (cursor == &this._head)
            return this.insertAfter(cursor, value);
        auto node = new shared(Node)(value);
        shared(Node)* next;
        auto prev = clearlsb(cursor._prev);

        while (true)
        {
            while (haslsb(cursor._next))
            {
                this.next(cursor);
                if (correctPrev(prev, cursor))
                    prev = clearlsb(cursor._prev);
            }
            assert(!haslsb(cursor));
            next = cursor;
            node._prev = prev;
            node._next = next;
            if (cas(&prev._next, next, node))
                break;
            if (correctPrev(prev, cursor))
                prev = clearlsb(cursor._prev);
        }
        cursor = cast(shared)node;
        correctPrev(prev, next);
    }

    void insertAfter(ref shared(Node)* cursor, shared T value)
    {
        assert(!haslsb(cursor));
        if (cursor == &this._tail)
            return this.insertBefore(cursor, value);
        auto node = new shared(Node)(value);
        auto prev = cursor;
        shared(Node)* next;

        while (true)
        {
            next = clearlsb(prev._next);
            node._next = next;
            node._prev = prev;
            if (cas(&cursor._next, next, node))
                break;

            if (haslsb(prev._next))
            {
                // delete node
                return this.insertBefore(cursor, value);
            }
        }
        cursor = cast(shared)node;
        correctPrev(prev, next);
    }

private:

    void linkPrev(shared(Node)* node, shared(Node)* next)
    {
        shared(Node)* link1;
        do
        {
            link1 = next._prev;
            if (haslsb(link1) || node._next != next)
                return;
        } while (!cas(&next._prev, link1, clearlsb(node)));

        if (haslsb(node._prev))
            correctPrev(node, next);
    }

    bool correctPrev(shared(Node)* prev, shared(Node)* node)
    {
        assert(!haslsb(prev));
        assert(!haslsb(node));
        assert(prev != bottom);
        assert(node != bottom);

        shared(Node)* lastlink = bottom;
        while (true)
        {
            //! store link1 for later cas
            auto link1 = node._prev;
            if (haslsb(node._next))
                return false;
            auto prev2 = prev._next;

            if (haslsb(prev2))
            {
                if (lastlink == bottom)
                {
                    prev = clearlsb(prev._prev);
                    //          prev = prev._prev;
                }
                else
                {
                    setMark(&prev._prev);
                    //          assert(!haslsb(lastlink._next));
                    cas(&lastlink._next, prev, clearlsb(prev2));
                    prev = lastlink;
                    lastlink = bottom;
                }
                continue;
            }

            if (prev2 != node)
            {
                lastlink = prev;
                prev = prev2;
                continue;
            }

            if (cas(&node._prev, link1, clearlsb(prev)))
            {
                if (haslsb(prev._prev))
                    continue;
                else
                    break;
            }
        }
        return true;
    }

    void setMark(shared(Node*)* link)
    {
        shared(Node)* p;
        do
        {
            p = *link;
        } while(!haslsb(p) && !cas(link, p, setlsb(p)));
    }
}


////////////////////////////////////////////////////////////////////////////////
// synchronized implementation
////////////////////////////////////////////////////////////////////////////////

synchronized class SyncedDList(T)
{
    struct Node
    {
        private Node* _prev;
        private Node* _next;
        private union
        {
            uint sentinel;
            T _payload;
        }

        this (shared T payload)
        {
            this._payload = payload;
        }

        @property shared(Node)* next() shared
        {
            return this._next;
        }

        @property shared(Node)* prev() shared
        {
            return this._prev;
        }
    }

    private Node _head;
    private Node _tail;
    enum bottom = clearlsb(cast(Node*)0xdeadbeafdeadbeaf);

    string dump() const
    {
        auto res = "";
        Node* pNode = cast(Node*)&this._head;
        do
        {
            res ~= to!string(pNode) ~ "->";
            pNode = pNode._next;
        } while (pNode != cast(Node*)&this._tail);
        res ~= to!string(pNode) ~ "\n";
        auto rev = "";
        do
        {
            rev = "<-" ~ to!string(pNode) ~ rev;
            pNode = pNode._prev;
        } while (pNode != cast(Node*)&this._head);
        rev = to!string(pNode) ~ rev;
        return res ~ rev;
    }

    this()
    {
        this._head._prev = bottom;
        this._head._next = &this._tail;
        this._head.sentinel = 0xdeadbeef;
        this._tail._prev = &this._head;
        this._tail._next = bottom;
        this._tail.sentinel = 0xdeadbeef;
    }

    bool empty()
    {
        return this._head._next == &this._tail;
    }

    void pushFront(shared T value)
    {
        auto newNode = new shared(Node)(value);
        newNode._next = this._head._next;
        newNode._prev = &this._head;
        this._head._next = newNode;
        newNode._next._prev = newNode;
    }

    void pushBack(shared T value)
    {
        auto newNode = new shared(Node)(value);
        newNode._next = &this._tail;
        newNode._prev = this._tail._prev;
        this._tail._prev = newNode;
        newNode._prev._next = newNode;
    }

    @property shared(T)* popFront()
    {
        if (this.empty)
            return null;
        else
        {
            shared(Node)* node = this._head._next;
            this._head._next = node._next;
            node._next._prev = &this._head;
            return &node._payload;
        }
    }

    @property shared(T)* popBack()
    {
        if (this.empty)
            return null;
        else
        {
            shared(Node)* node = this._tail._prev;
            this._tail._prev = node._prev;
            node._prev._next = &this._tail;
            return &node._payload;
        }
    }

    bool next(ref shared(Node)* cursor)
    {
        if (cursor == &this._tail)
            return false;
        else
        {
            cursor = cursor._next;
            return true;
        }
    }

    bool prev(ref shared(Node)* cursor)
    {
        if (cursor == &this._head)
            return false;
        else
        {
            cursor = cursor._prev;
            return true;
        }
    }

    shared(T)* deleteNode(ref shared(Node)* cursor)
    {
        if (cursor == &this._head || cursor == &this._tail)
            return null;
        else
        {
            shared(Node)* node = cursor;
            node._prev._next = node._next;
            node._next._prev = node._prev;
            return &node._payload;
        }
    }

    void insertBefore(ref shared(Node)* cursor, shared T value)
    {
        if (cursor == &this._head)
            return this.insertAfter(cursor, value);
        else
        {
            auto node = cast(shared)new Node(value);
            node._next = cursor;
            node._prev = cursor._prev;
            cursor._prev._next = node;
            cursor._prev = node;
        }
    }

    void insertAfter(ref shared(Node)* cursor, in T value)
    {
        if (cursor == &this._tail)
            return this.insertBefore(cursor, value);
        else
        {
            auto node = cast(shared)new Node(value);
            node._prev = cursor;
            node._next = cursor._next;
            cursor._next._prev = node;
            cursor._next = node;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////
// lsb helper
////////////////////////////////////////////////////////////////////////////////

private:

static bool haslsb(T)(T* p)
{
    return (cast(size_t)p & 1) != 0;
}

static T* setlsb(T)(T* p)
{
    return cast(T*)(cast(size_t)p | 1);
}

static T* clearlsb(T)(T* p)
{
    return cast(T*)(cast(size_t)p & ~1);
}

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

version (unittest):

unittest
{
    auto testList = new shared(TList)();
    testList.pushFront(cast(shared)TPayload(0));
    auto cursor = &testList._head;
    testList.next(cursor);
    cursor._next = setlsb(cursor._next);
    cursor._prev = setlsb(cursor._prev);
    testList.insertBefore(cursor, cast(shared)TPayload(1));
}

unittest
{
    auto testList = new shared(TList)();
    assert(testList._head._next == &testList._tail);
    assert(testList._tail._prev == &testList._head);

    testList.pushFront(cast(shared)TPayload(0));
    assert(testList._head._next != &testList._tail);
    assert(testList._tail._prev != &testList._head);
    assert(testList._head._next._next == &testList._tail);
    assert(testList._tail._prev._prev == &testList._head);
    assert(testList._head._next._payload == cast(shared)TPayload(0));

    auto pValue = testList.popFront();
    assert(testList._head._next == &testList._tail);
    assert(testList._tail._prev == &testList._head);
    assert(*pValue == cast(shared)TPayload(0));
}

struct Heavy
{
    this (size_t val)
    {
        this.val[0] = val;
    }
    size_t[16] val;
}

struct Light
{
    this (size_t val)
    {
        this.val = val;
    }
    size_t val;
}

alias Light TPayload;
alias shared AtomicDList!(TPayload) TList;
//alias SyncedDList!(TPayload) TList;
shared TList sList;
enum amount = 10_000;
enum Position { Front, Back, }

void adder(Position Where)()
{
    size_t count = amount;
    do
    {
        static if (Where == Position.Front)
            sList.pushFront(cast(shared)TPayload(count));
        else
            sList.pushBack(cast(shared)TPayload(count));
    } while (--count);
}

void remover(Position Where)()
{
    size_t count = amount;
    do
    {
        static if (Where == Position.Front)
            while (sList.popFront() is null) {}
        else
            while (sList.popBack() is null) {}
    } while (--count);
}

void iterAdder(Position Where)()
{
    size_t count = amount;
    static if (Where == Position.Front)
    {
        do
        {
            auto cursor = &sList._head;
            do
            {
                sList.insertAfter(cursor, cast(shared)TPayload(count));
            } while (--count && sList.next(cursor));
        } while (count);
    }
    else
    {
        do
        {
            auto cursor = &sList._tail;
            do
            {
                sList.insertBefore(cursor, cast(shared)TPayload(count));
            } while (--count && sList.prev(cursor));
        } while (count);
    }
}

void iterRemover(Position Where)()
{
    size_t count = amount;
    static if (Where == Position.Front)
    {
        do
        {
            auto cursor = &sList._head;
            do
            {
                sList.next(cursor);
            } while (sList.deleteNode(cursor) !is null && --count);
        } while (count);
    }
    else
    {
        do
        {
            auto cursor = &sList._tail;
            do
            {
                sList.prev(cursor);
            } while (sList.deleteNode(cursor) !is null && --count);
        } while (count);
    }
}

void iterator(Position Where)()
{
    size_t max_steps;
    size_t times = amount;
    static if (Where == Position.Front)
    {
        do
        {
            size_t steps;
            auto cursor = &sList._head;
            while (sList.next(cursor)) { ++steps; }
            assert(cursor == &sList._tail);
            max_steps = max(max_steps, steps);
        } while (--times);
    }
    else
    {
        do
        {
            size_t steps;
            auto cursor = &sList._tail;
            while (sList.prev(cursor)) { ++steps; }
            assert(cursor == &sList._head);
            max_steps = max(max_steps, steps);
        } while (--times);
    }
    writefln("size %s", max_steps);
}

unittest
{
    import std.parallelism : totalCPUs;

    sList = new shared(TList)();
    size_t count;
    shared(TList.Node)* p;

    foreach(i; 0 .. totalCPUs)
    {
        if (i & 1)
        {
            spawn(&remover!(Position.Back));
            spawn(&adder!(Position.Front));
            spawn(&iterator!(Position.Back));
        }
        else
        {
            spawn(&adder!(Position.Back));
            spawn(&remover!(Position.Front));
            spawn(&iterator!(Position.Front));
        }
    }

    thread_joinAll();
    count = 0;
    p = sList._head.next;
    while (p !is &sList._tail)
    {
        ++count;
        p = p.next;
    }
    writeln("queue empty? -> ", count);
    assert(count == 0, to!string(count));

    foreach(i; 0 .. totalCPUs)
    {
        if (i & 1)
        {
            spawn(&iterRemover!(Position.Front));
            spawn(&iterAdder!(Position.Back));
            spawn(&iterator!(Position.Back));
        }
        else
        {
            spawn(&iterAdder!(Position.Front));
            spawn(&iterRemover!(Position.Back));
            spawn(&iterator!(Position.Front));
        }
    }

    thread_joinAll();
    count = 0;
    p = sList._head.next;
    while (p !is &sList._tail)
    {
        ++count;
        p = p.next;
    }
    writeln("list empty? -> ", count);
    assert(count == 0, to!string(count));

    foreach(i; 0 .. totalCPUs)
    {
        if (i & 1)
        {
            spawn(&iterator!(Position.Back));
            spawn(&iterRemover!(Position.Front));
            spawn(&adder!(Position.Front));
            spawn(&iterAdder!(Position.Front));
            spawn(&remover!(Position.Back));
            spawn(&iterator!(Position.Front));
        }
        else
        {
            spawn(&iterator!(Position.Front));
            spawn(&iterAdder!(Position.Back));
            spawn(&remover!(Position.Front));
            spawn(&iterRemover!(Position.Front));
            spawn(&adder!(Position.Back));
            spawn(&iterator!(Position.Front));
        }
    }

    thread_joinAll();
    count = 0;
    p = sList._head.next;
    while (p !is &sList._tail)
    {
        ++count;
        p = p.next;
    }
    writeln("mixed empty? -> ", count);
    assert(count == 0, to!string(count));
}
