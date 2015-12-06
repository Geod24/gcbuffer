/*******************************************************************************

    gcbuffer: Standalone GC buffer usable in @nogc code

    This module provides a buffer integrated with the GC and `@nogc`.
    How does that work ?

    assumeSafeAppend:
    There is a little gem in the object module, inherited from the old D1 days,
    which is the `assumeSafeAppend` function. If you were to reduce an array's
    length, or to slice off the end of it, and then append to that slice, the
    GC would reallocate, because else it might be overriding data still in use.
    That's a sane behaviour, but not always what you want. Sometimes you know
    you will discard the data and thus it's safe to append in place. That's
    what `assumeSafeAppend` is for, telling the GC to override if it can.

    nogc:
    The `@nogc` compiler-reckognized attribute was introduced in 2.067, as a
    mean to reduce the language's dependency on the GC. It doesn't have any
    effect on the code, and will just issue a compile error if you are doing
    something that will allocate, or if you're calling a non-`@nogc` function.
    It is great, but it's an all-or-nothing approach: sometimes you want your
    app to allocate up to a certain amount, then it should not allocate anymore.
    And as soon as you have a non-`@nogc` function in your call chain, you
    cannot allocate any function up the call list with `@nogc`.

    Solution:
    The `GCBuffer` struct wraps an array of elements which can be stomped.
    The other major advantage of this is that expanding the array (by means
    of `~=` or setting the `length`) is marked as `@nogc`.

    Why would you do that, and when do you want to use it ?
    You are mostly interested in this kind of approach in long-living processes,
    such as servers. A server will usually allocates such buffer, and reuse
    it, as allocation and deallocation are expensive operations.
    With this approach, you can ensure that you don't allocate new memory
    on each request, but only use the buffers, which can be expanded if needed.

    Of course this is a dangerous approach, as it is changing the meaning of
    `@nogc`, and should not be considered lightly. It's important to always
    keep in mind the lifetime of slices taken of such buffer.

    Authors: Mathias 'Geod24' Lang
    Copyright: 2015 - Mathias Lang
    License: BSL (Boost) 1.0

*******************************************************************************/

module gcbuffer.buffer;

/*******************************************************************************

    GCBuffer implementation

    This struct aims to be minimal. All members are declared as `nothrow @nogc`
    expect for the constructor which creates a new array. This was done as the
    reason to circumvent `@nogc` is to ensure that no new allocation happens,
    which would go undetected if creating a new buffer wasn't detected as @nogc.
    If you really need to work around this problem, use an inline delegate and
    cast it:

    ----
    auto buff = (cast(void delegate() @nogc nothrow)(){return GCBuffer();})();
    ----

    GCBuffer doesn't allow for arrays of `immutable` or `const` elements.
    It's already unsafe enough.

    Template_Params:
        ElementType = The type of the element this array will hold. For example,
                        if it's an HTTP buffer, and you want to store
                        characters, you will use a `GCBuffer!char` (which
                        works as a `char[]`). The `ElementType` should not be
                        `immutable` nor `const`.

*******************************************************************************/

public struct GCBuffer (ElementType)
{
    nothrow:

    static assert (!is(ElementType == const),
                   "Cannot have a const buffer");
    static assert (!is(ElementType == immutable),
                   "Cannot have an immutable buffer");

    /***************************************************************************

        Creates a new buffer with a preallocated array of the specified size

        This is the most straightforward way to create a new buffer.
        It will allocate a new array with the given capacity. You don't need to
        change this value, as the buffer will grow naturaly when needed.
        However, be advised that many small append, while okay on the long run,
        could trigger many memory allocations (which would get GC collected at
        some point) during 'warm up' (that is, until the buffer reach its final
        capacity).

        Note:
        As mentioned in the struct documentation, this constructor is the only
        not-`@nogc` member. If you really need a `@nogc` constructor, either
        use the delegate cast trick, or the second constructor, passing it
        an already allocated array, or `null`.

        Params:
            capacity = Initial capacity this buffer will have. We suggest 128.

    ***************************************************************************/

    public this (size_t capacity)
    {
        if (capacity)
        {
            this.buffer = new ElementType[](capacity);
            this.buffer.length = 0;
        }
    }

    @nogc:

    /***************************************************************************

        Wraps an already existing array to be used with reusable semantic.

        The array content will be left intact, though any further slicing or
        resizing will potentially override content.

        Params:
            buff = The buffer to wrap and use internally. After the call,
                    any reference to `buff` should be discarded are they will
                    be unsafe to use.
                    `null` is a valid argument and will not just initialize
                    any buffer, leading to a slightly longer buffer warm up.

    ***************************************************************************/

    public this (ElementType[] buff)
    {
        this.buffer = buff;
    }

    /***************************************************************************

        Get the 'raw' array

        This low-level function is there for when you really need the reference,
        though it should not be needed as this buffer use 'alias this'.

        Returns:
        The current internal buffer.

    ***************************************************************************/

    public ElementType[] getRaw () { return this.buffer; }

    /// Alias this to the buffer
    public alias getRaw this;

    /// Private member
    private ElementType[] buffer;


    /***************************************************************************

        opAssign on this struct is disabled by default

        This is done as a mean to prevent unintentional buffer switch.
        If you need to override a `GCBuffer`, you can assign it a buffer
        initialized with the second constructor.

    ***************************************************************************/

    @disable public void opAssign (ElementType[] rhs);


    /***************************************************************************

        Append to this buffer

    ***************************************************************************/

    public typeof(this) opOpAssign (string op, ET) (ET rhs)
    if (op == "~")
    {
        appendProxy(this.buffer, rhs);
        return this;
    }


    /***************************************************************************

        Handle `.length` property (getter and setter)

        If you wish to reset that buffer, use `buffer.length = 0`.
        Expanding the buffer is also possible.

    ***************************************************************************/

    public size_t length () const @property { return this.buffer.length; }

    /// Ditto
    public void length (size_t new_length) @property
    {
        setLengthProxy(this.buffer, new_length);
    }


    /***************************************************************************

        Output range function definition

        Note:
        isOutputRange checks explicitly for a 'member' put, thus we cannot
        provide an alias to `~=`.

    ***************************************************************************/

    public void put (ElementType e)
    {
        this ~= e;
    }
}

///
@nogc unittest
{
    import std.format, std.range;

    static assert(isOutputRange!(GCBuffer!char, char));

    GCBuffer!(char) buffer;
    // Initialize - Long enough so that it doesn't reallocate
    buffer.length = 128; buffer.length = 0;

    auto orig_ptr = buffer.ptr;
    buffer ~= "Promenons nous";
    buffer ~= ' ';
    buffer ~= "dans";
    buffer ~= ' ';
    buffer ~= "les";
    buffer ~= ' ';
    buffer ~= "bois";

    assert(orig_ptr is buffer.ptr, "GCBuffer reallocated");
    assert(buffer.length == 28, "Length mismatch");

    // Make sure reallocation change the pointer
    GCBuffer!char buffer2;
    buffer2.length = 128;

    // Simple test of reset
    buffer.length = 0;
    buffer ~= "I am a poor lonesome cowboy, and a long long way from home";
    assert(orig_ptr is buffer.ptr, "GCBuffer reallocated");
    assert(buffer.length == 58, "Length mismatch");

    // Now make it expand, not in place
    buffer ~= "I am a poor lonesome cowboy, and a long long way from home";
    buffer ~= "I am a poor lonesome cowboy, and a long long way from home";
    buffer ~= "I am a poor lonesome cowboy, and a long long way from home";
    buffer ~= "I am a poor lonesome cowboy, and a long long way from home";
    // We added 58 * 5 => 290 bytes, the capacity was 128, so it probably
    // reallocated to a wider buffer.
    assert(orig_ptr !is buffer.ptr, "GCBuffer did not reallocate?");
    assert(buffer.length == 290, "Length mismatch");

    // TODO: formattedWrite is not @nogc
    /*
    auto old_ptr = buffer.ptr;
    formattedWrite(
        buffer, "{} {} {}",
        "Lorem ipsum vae victum", ulong.max,
        "some very long text that will hopefully cause reallocation from the "
        ~ "GCBuffer so that we can test if formattedWrite handles it correctly");
    */
}


/*******************************************************************************

    Private copy of `object.assumeSafeAppend`

    This is a clone of `assumeSafeAppend` which is used internally
    in `GCBuffer`.
    The implementation is the same, with the only difference that the underlying
    `extern (C)` function called is annotated with `@nogc`.

*******************************************************************************/

private auto ref inout(T[]) stomp(T)(auto ref inout(T[]) arr) nothrow @nogc
{
    _d_arrayshrinkfit(typeid(T[]), *(cast(void[]*)&arr));
    return arr;
}

/// Ditto
private extern(C) void _d_arrayshrinkfit(const TypeInfo ti, void[] arr) nothrow @nogc;


/*******************************************************************************

    Workaround for `@nogc`

    We cannot use an inline delegate as DMD detects it before the cast.

*******************************************************************************/

private void appendProxy (ET, T) (ref ET[] arr, T e) nothrow @nogc
{
    (cast(void function(ref ET[], T) nothrow @nogc) &append!(ET, T))(arr, e);
}

/// Ditto
private void append (ET, T) (ref ET[] arr, T e) nothrow /* @nogc */
{
    arr.stomp ~= e;
}

/// Ditto
private void setLengthProxy (ET) (ref ET[] arr, size_t len) nothrow @nogc
{
    (cast(void function(ref ET[], size_t) nothrow @nogc) &setLength!(ET))(arr, len);
}

/// Ditto
private void setLength (ET) (ref ET[] arr, size_t len) nothrow /* @nogc */
{
    arr.length = len;
}
