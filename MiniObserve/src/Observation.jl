module Observation

export print_header, @observe, log_results

using MacroTools

"obtain a named tuple type with the same field types and names as `struct_T`"
tuple_type(struct_T) = NamedTuple{fieldnames(struct_T), Tuple{fieldtypes(struct_T)...}}

"construct a named tuple from `x`"
@generated function to_named_tuple(x)
	if x <: NamedTuple
		return :x
	end

	# constructor call
	tuptyp = Expr(:quote, tuple_type(x))
	
	# constructor arguments
	tup = Expr(:tuple)
	for i in 1:fieldcount(x)
		push!(tup.args, :(getfield(x, $i)) )
	end
	
	# both put together
	:($tuptyp($tup))
end


"translate accumulator types into prefixes for the header (e.g. min, max, etc.)"
stat_names(::Type{T}) where {T} = fieldnames(result_type(T))

# We could make this a generated function as well, but since the header
# is only printed once at the beginning, the additional time needed for
# runtime introspection is worth the reduction in complexity.
"Print a header for an observation type `stats_t` to `output` using field separator `FS`, name separator `NS` and line separator `LS`."
function print_header(output, stats_t; FS="\t", NS="_", LS="\n")
	fn = fieldnames(stats_t)
	ft = fieldtypes(stats_t)

	for (i, (name, typ)) in enumerate(zip(fn, ft))
		if typ <: NamedTuple
			# aggregate stat
			header(output, string(name), string.(fieldnames(typ)), FS, NS)
		else
			# single stat
			print(output, string(name))
		end

		if i < length(fn)
			print(output, FS)
		end
	end

	print(output, LS)
end

# print header for aggregate stat
function header(out, stat_name, stat_names, FS, NS)
	@assert length(stat_names) > 0

	print(out, join((stat_name * NS) .* stat_names, FS))
end

# It's quite possibly overkill to make this a generated function, but we
# don't want anybody accusing us of wasting CPU cycles.
"Print results stored in `stats` to `output` using field separator `FS` and line separator `LS`."
@generated function log_results(out, stats; FS="\t", LS="\n")
	fn = fieldnames(stats)
	ft = fieldtypes(stats)

	fn_body = Expr(:block)

	# all fields of stats
	for (i, (name, typ)) in enumerate(zip(fn, ft))
		# aggregate stats
		if typ <: NamedTuple
			# go through all elements of stats.name
			for (j, tname) in enumerate(fieldnames(typ))
				push!(fn_body.args, :(print(out, stats.$name.$tname)))
				if j < length(fieldnames(typ))
					push!(fn_body.args, :(print(out, FS)))
				end
			end
		# single values
		else
			push!(fn_body.args, :(print(out, stats.$name)))
		end

		if i < length(fn)
			push!(fn_body.args, :(print(out, FS)))
		end
	end

	push!(fn_body.args, :(print(out, LS)))

	fn_body
end


# process a single stats declaration (@record)	
function process_single(name, typ, expr)
	# no type specified, default to float
	if typ == nothing
		typ = :Float64
	end

	tmp_name = gensym("tmp")
	:($tmp_name = $(esc(expr)))

	[:($name :: $(esc(typ)))],	# type
		[:($tmp_name = $(esc(expr)))],	# body
		[:($tmp_name)]					# constructor
end

# it would be much nicer to use a generated function for this, but
# unfortunately we are already operating on types
"concatenate named tuple and/or struct types into one single named tuple"
function joined_named_tuple_T(types...)
	ns = Expr(:tuple)
	ts = Expr(:curly)
	push!(ts.args, :Tuple)
	
	for t in types
		fnames = fieldnames(t)
		ftypes = fieldtypes(t)

		append!(ns.args, QuoteNode.(fnames))
		append!(ts.args, ftypes)
	end
	
	ret = :(NamedTuple{})
	push!(ret.args, ns)
	push!(ret.args, ts)

	eval(ret)
end


# process an aggregate stats declaration (@for)
function process_aggregate(var, collection, decls)
	stat_type_code = []
	body_code = []
	res_code = []

	decl_code = []
	loop_code = []

	lines = rmlines(decls).args

	for (i, line) in enumerate(lines)
		@capture(line, @stat(statname_String, stattypes__) <| expr_) ||
			error("expected:@stat(<NAME>, <STAT> {, <STAT>}) <| <EXPR>")

		# code to declare stat property in stats struct
		# creates a single named tuple type from all result types of all stats
		sname = Symbol(statname)
		prop_code = :($sname :: joined_named_tuple_T())
		for t in stattypes
            # not a constructor call
            if ! @capture(t, typ_(args__))
                typ = t
            end

			push!(prop_code.args[2].args, :($(esc(:result_type))($(esc(typ)))))
		end

		push!(stat_type_code, prop_code)

		# code to store result of user code (to be fed into stats objects)
		# (inside loop)
		tmp_name = gensym("tmp")
		push!(loop_code, :($tmp_name = $(esc(expr))))

		# expression that merges all results for this stat into single named tuple
		res_expr = length(stattypes) > 1 ? :(merge()) : :(identity())

		# all stats for this specific term
		for (j, stattype) in enumerate(stattypes)
			# declaration of accumulator
			vname = gensym("stat")
            # goes into main body (outside of loop)
            if @capture(stattype, typ_(args__))
                # paste in constructor expression
                push!(body_code, :($(esc(vname)) = $(esc(stattype))))
            else
                # create constructor call
                push!(body_code, :($(esc(vname)) = $(esc(stattype))()))
            end

			# add value to accumulator
			push!(loop_code, :($(esc(:add!))($(esc(vname)), $tmp_name)))
			# add to named tuple argument of constructor call
			push!(res_expr.args, :(to_named_tuple($(esc(:results))($(esc(vname))))))
		end
		
		# another argument for the main constructor call
		push!(res_code, res_expr)

	end

	# add the loop to the main body
	push!(body_code, :(for $(esc(var)) in $(esc(collection)); $(loop_code...); end))

	stat_type_code, body_code, res_code
end


""" 

@observe(statstype, model [, user_arg1...], declarations)

Generate a full analysis suite for a model.

Given a declaration

```Julia
@observe Data model user1 user2 begin
	@record "time"      model.time
	@record "N"     Int length(model.population)

	@for ind in model.population begin
		@stat("capital", MaxMinAcc{Float64}, MeanVarAcc{FloatT}) <| ind.capital
		@stat("n_alone", CountAcc)           <| has_neighbours(ind)
	end

	@record u1			user1
	@record u2			user1 * user2
end
```

a type Data will be generated that provides (at least) the following members:

```Julia
struct Data
	time :: Float64
	N :: Int
	capital :: @NamedTuple{max :: Float64, min :: Float64, mean :: Float64, var :: Float64}
	n_alone :: @NamedTuple{N :: Int}
	u1 :: Float64
	u2 :: Float64
end
```

The macro will also create a method for `observe(::Type{Data), model...)` that will perform the required calculations and returns a `Data` object. Use `print_header` to print a header for the generated type to an output and `log_results` to print the content of a data object.
"""
macro observe(tname, model, args_and_decl...)
	observe_syntax = "@observe <type name> <model> [<user args> ...] <declaration block>"

	if typeof(tname) != Symbol
		error("usage: $observe_syntax")
	end

	if length(args_and_decl) < 1
		error("usage: $observe_syntax")
	end

	decl = args_and_decl[end]

	if typeof(decl) != Expr || decl.head != :block
		error("usage: $observe_syntax")
	end

	ana_func = if length(args_and_decl) == 1
		:(function $(esc(:observe))(::$(esc(:Type)){$(esc(tname))}, $(esc(model))); end)
	else
		:(function $(esc(:observe))(::$(esc(:Type)){$(esc(tname))}, $(esc(model)), 
			$(esc(args_and_decl[1:end-1]...))); end)
	end

	ana_body = ana_func.args[2].args

	stats_type = :(struct $(esc(tname)); end)

	stats_constr = :($(esc(tname))())

	syntax = "single or population stats declaration expected:\n" *
		"\t@for <NAME> in <EXPR> <BLOCK> |" *
		"\t@record <NAME> <EXPR> |" *
		"\t@record <NAME> <TYPE> <EXPR>"
	
	# go through declaration expression by expression
	# each expression is translated into three bits of code:
	# * additional fields for the stats type
	# * additional code to run during the analysis
	# * additional arguments for the stats object constructor call
	lines = rmlines(decl).args
	for (i, line) in enumerate(lines)
		if typeof(line) != Expr || line.head != :macrocall
			dump(line)
			error(syntax)
		end
		
		# single stat
		if line.args[1] == Symbol("@record")
			typ = nothing
			@capture(line, @record(name_String, expr_)) || 
				@capture(line, @record(name_String, typ_, expr_)) ||
				error("expecting: @record <NAME> [<TYPE>] <EXPR>")
			stats_type_c, ana_body_c, stats_constr_c = 
				process_single(Symbol(name), typ, expr)

		# aggregate stat
		elseif line.args[1] == Symbol("@for")
			@capture(line, @for var_Symbol in expr_ begin block_ end) ||
				error("expecting: @for <NAME> in <EXPR> <BLOCK>")
			stats_type_c, ana_body_c, stats_constr_c = 
				process_aggregate(var, expr, block)

		else
			error(syntax)
		end

		# add code to respective bits
		append!(ana_func.args[2].args, ana_body_c)
		append!(stats_type.args[3].args, stats_type_c)
		append!(stats_constr.args, stats_constr_c)
	end

	# add constructor call as last line of analysis function
	push!(ana_func.args[2].args, stats_constr)

	ret = Expr(:block)
	push!(ret.args, stats_type)
	push!(ret.args, ana_func)

	ret
end

end	# module
