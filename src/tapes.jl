###########
# Untrack #
###########

struct Untrack{F} <: Function
    func::F
end

@inline Untrack(u::Untrack) = u

@inline (u::Untrack{<:Any})(a) = u.func(untrack(a))
@inline (u::Untrack{<:Any})(a, b) = u.func(untrack(a), untrack(b))
@inline (u::Untrack{<:Any})(a, b, c) = u.func(untrack(a), untrack(b), untrack(c))
@inline (u::Untrack{<:Any})(a, b, c, d) = u.func(untrack(a), untrack(b), untrack(c), untrack(d))
@inline (u::Untrack{<:Any})(a, b, c, d, e) = u.func(untrack(a), untrack(b), untrack(c), untrack(d), untrack(e))
@inline (u::Untrack{<:Any})(a, b, c, d, e, others...) = u.func(untrack(a), untrack(b), untrack(c), untrack(d), untrack(e), untrack.(others)...)

##########
# Record #
##########

struct Record{G<:AbstractGenre,F} <: Function
    genre::G
    func::F
end

@inline function (r::Record{ValueGenre})(output, input)
    output_note = track(output, r.genre)
    output_note.parent = FunctionNote(r.genre, r.func, input)
    return output_note
end

@inline (r::Record{ValueGenre})(output, ::Tuple{<:DataType}) = track(output, r.genre)

###########
# Execute #
###########

struct Execute{G<:AbstractGenre,F} <: Function
    genre::G
    func::F
end

@inline (e::Execute)(input...) = call_record(Record(e.genre, e.func), Untrack(e.func)(input...), input)
@inline (e::Execute)(::Type{T}) where {T} = call_record(Record(e.genre, e.func), Untrack(e.func)(T), (T,))

@inline call_record(r::Record, output::NTuple{N}, input::Tuple, args...) where {N} = NTuple{N}(r(o, input, args...) for o in output)
@inline call_record(r::Record, output, input::Tuple, args...) = call_record(trackability(output), r, output, input, args...)
@inline call_record(::TrackabilityTrait, r::Record, output, input::Tuple, args...) = r(output, input, args...)
@inline call_record(::NotTrackable, r::Record, output, input::Tuple, args...) = output

#############
# Intercept #
#############

struct Intercept{F} <: Function
    func::F
end

@inline Intercept(i::Intercept) = i

@inline (i::Intercept)(input...) = Execute(promote_genre(input...), i.func)(input...)
@inline (i::Intercept)(::Type{T}) where {T} = Execute(genre(T), i.func)(T)

#=
works for the following formats:
- `@intercept(f)(args...)`
- `@intercept f(args...) = ...`
- `@intercept function f(args...) ... end`
- `@intercept f = (args...) -> ...`
=#
macro intercept(expr)
    if isa(expr, Expr) && (expr.head == :(=) || expr.head == :function)
        lhs = expr.args[1]
        if isa(lhs, Expr) && lhs.head == :call # named function definition site
            name_and_types = lhs.args[1]
            if isa(name_and_types, Expr) && name_and_types.head == :curly
                old_name = name_and_types.args[1]
                hidden_name = Symbol("#cassette_hidden_$(old_name)")
                name_and_types.args[1] = hidden_name
            elseif isa(name_and_types, Symbol)
                old_name = name_and_types
                hidden_name = Symbol("#cassette_hidden_$(old_name)")
                lhs.args[1] = hidden_name
            else
                error("failed to apply Cassette.@intercept to expression $(expr); potentially malformed function signature?")
            end
            result = quote
                $expr
                if !(isdefined($(Expr(:quote, old_name))))
                    const $(old_name) = $(Intercept)($(hidden_name))
                end
            end
        elseif isa(lhs, Symbol) # variable assignment site
            expr.args[2] = :($(Intercept)($(expr.args[2])))
            result = expr
        else
            error("failed to apply Cassette.@intercept to expression $expr")
        end
    else # call site
        result = :($(Intercept)($expr))
    end
    return esc(result)
end

########
# Tape #
########

# Dub #
#-----#

struct Dub{G<:AbstractGenre,F,I<:Tuple,O,C}
    genre::G
    func::F
    input::I
    output::O
    cache::C
end

@inline Dub(note::FunctionNote, output, cache = nothing) = Dub(note.genre, note.func, note.input, output, cache)

# Playing Dubs #
#--------------#

abstract type PlayMode end

struct ForwardMode <: PlayMode end
struct ReverseMode <: PlayMode end

const PlayWrapper = FunctionWrappers.FunctionWrapper{Void,Tuple{}}

struct Play{D<:Dub,M<:PlayMode} <: Function
    dub::D
    mode::M
end

@noinline (p::Play)() = (play!(p.dub, p.mode); nothing)

# play! #
#-------#

@inline function play!(dub::Dub{ValueGenre,<:Any,<:Tuple,<:RealNote}, ::ForwardMode)
    dub.output.value += Untrack(dub.func)(dub.input...)
    return nothing
end

# Tape #
#------#

struct Tape
    dubs::Vector{Dub}
    forward::Vector{PlayWrapper}
    reverse::Vector{PlayWrapper}
    function Tape(dubs::Vector{Dub})
        forward = [PlayWrapper(Play(dubs[i], ForwardMode())) for i in 1:length(dubs)]
        reverse = [PlayWrapper(Play(dubs[i], ReverseMode())) for i in length(dubs):-1:1]
        return new(dubs, forward, reverse)
    end
end

function Tape(output::ValueNote)
    dubs = Vector{Dub}()
    walkback(output) do dub, hasparent
        hasparent && push!(dubs, Dub(dub.parent, dub))
    end
    return Tape(reverse!(dubs))
end

play!(t::Tape, ::ForwardMode) = (for f! in t.forward; f!(); end; nothing)
play!(t::Tape, ::ReverseMode) = (for f! in t.reverse; f!(); end; nothing)
