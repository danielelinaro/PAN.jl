module PAN

using Libdl
using BinDeps
import Base.Filesystem.splitdir

export load_libs, load_netlist, exec_cmd, get_var, tran, shooting, alter, envelope, DC, PZ

PAN_LIB_PATH = ENV["JUPAN_SO"]
VERBOSE = false


# this function is necessary because Libdl.find_library does
# not provide the correct full name of the shared library
function find_shared_library(lib_name::String)
    @BinDeps.setup
    if length(lib_name) < 4 || lib_name[1:3] != "lib"
        deps = library_dependency(string("lib", lib_name))
    else
        deps = library_dependency(lib_name)
    end
    str = split(string(deps), "- System Paths at ")
    full_path = rstrip(str[2])
    return splitdir(full_path)
end


function load_libs(pan_lib_path::String)
    libs = Dict{String,Ptr{Nothing}}()
    lib_names = ("c", "m", "z", "bz2", "history", "gfortran")
    for lib_name in lib_names
        path,full_name = find_shared_library(lib_name)
        libs[lib_name] = dlopen(full_name, RTLD_GLOBAL)
        if VERBOSE
            println("Successfully loaded library ", full_name, " @ ", path)
        end
    end
    libs["pan"] = dlopen(pan_lib_path, RTLD_LAZY | RTLD_GLOBAL)
    return libs
end


function load_netlist(filename::String, libs::Any = nothing)
    if ! isfile(filename)
        println(filename, ": no such file.")
        return false, libs
    end

    if isnothing(libs)
        libs = load_libs(PAN_LIB_PATH)
    end

    func_ptr = dlsym(libs["pan"], "InitialiseGlobals", throw_error=true)
    # InitialiseGlobals takes no arguments, but I don't know how to pass
    # no arguments to a function
    ok = ccall(func_ptr, UInt8, (UInt8,), 0)
    if ok != 1
        return false, libs
    end

    func_ptr = dlsym(libs["pan"], "JuliaPanInit", throw_error=true)
    argv = ["pan", filename]
    err = ccall(func_ptr, Int32, (Int32, Ptr{Ptr{UInt8}}), length(argv), argv)
    return err == 0, libs    
end


function exec_cmd(cmd::String, libs::Any = nothing)
    if isnothing(libs)
        libs = load_libs(PAN_LIB_PATH)
    end
    func_ptr = dlsym(libs["pan"], "PanJuliaExecuteCommand", throw_error=true)
    ccall(func_ptr, UInt8, (Ptr{UInt8},), cmd)
end


function get_var(varname::String, libs::Any = nothing)
    if isnothing(libs)
        libs = load_libs(PAN_LIB_PATH)
    end

    func_ptr = dlsym(libs["pan"], "PanJuliaGet", throw_error=true)
    rows = collect(Int32, 1)
    cols = collect(Int32, 1)
    real_part = collect(Ptr{Float64}, 1)
    imag_part = collect(Ptr{Float64}, 1)
    ok = ccall(func_ptr, Int32, (Ptr{UInt8}, Ptr{Ptr{Float64}}, Ptr{Ptr{Float64}}, Ptr{Int32}, Ptr{Int32}),
               varname, real_part, imag_part, rows, cols)
    if ok != 1
        throw(UndefVarError(Symbol(varname)))
    end
    
    if rows[1] > 1
        sz = rows[1]
    else
        sz = cols[1]
    end
    
    A = unsafe_wrap(Array, real_part[1], sz)
    try
        # get the imaginary part
        B = unsafe_wrap(Array, imag_part[1], sz)
    catch
        # there is no imaginary part
        return A
    end
    return A + im * B
end


function run_cmd_with_return_data(base_cmd::String, mem_vars::AbstractArray = [], libs::Any = nothing; kwargs...)
    if isnothing(libs)
        libs = load_libs(PAN_LIB_PATH)
    end
    ss = split(base_cmd, " ")
    analysis_name = ss[1]
    analysis_type = ss[2]
    cmd = string(base_cmd, " mem=[")
    for var in mem_vars
        cmd = string(cmd, "\"", var, "\", ")
    end
    cmd = string(cmd[1:end-2], "]")
    for (key,value) in kwargs
        cmd = string(cmd, " ", key, "=", value)
    end
    ok = exec_cmd(cmd, libs)
    if ok != 1
        error(analysis_type, " analysis ", analysis_name, " failed")
    end
    if length(mem_vars) > 0
        try
            data = [get_var(string(analysis_name, ".", var), libs) for var in mem_vars]
            return hcat(data...)
        catch e
            println("Some of the requested variables do not exist in PAN's memory.")
        end
    end
end


tran(name::String, tstop::Number, mem_vars::AbstractArray = [], libs::Any = nothing; kwargs...) =
    run_cmd_with_return_data(string(name, " tran tstop=", tstop), mem_vars, libs; kwargs...)


shooting(name::String, period::Number, mem_vars::AbstractArray = [], libs::Any = nothing; kwargs...) =
    run_cmd_with_return_data(string(name, " shooting period=", period), mem_vars, libs; kwargs...)


envelope(name::String, tstop::Number, period::Number,
         mem_vars::AbstractArray = [], libs::Any = nothing; kwargs...) =
             run_cmd_with_return_data(string(name, " envelope tstop=", tstop, " period=", period),
                                      mem_vars, libs; kwargs...)


DC(name::String, mem_vars::AbstractArray = [], libs::Any = nothing; kwargs...) =
    run_cmd_with_return_data(string(name, " dc"), mem_vars, libs; kwargs...)


function PZ(name::String, mem_vars::AbstractArray = [], libs::Any = nothing; kwargs...)
    if length(mem_vars) > 0
        base_cmd = string(name, " dc mem=1")
    else
        base_cmd = string(name, " dc")
    end
    # remove parameter 'mem', if present
    kwargs = [p for p in pairs(kwargs) if p[1] != :mem]
    run_cmd_with_return_data(base_cmd, [], libs; kwargs...)
    if length(mem_vars) > 0
        try
            data = [get_var(string(name, ".", var), libs) for var in mem_vars]
            return hcat(data...)
        catch e
            println("Some of the requested variables do not exist in PAN's memory.")
        end
    end
end


function alter(name::String, param::String, value::Number, libs::Any = nothing; kwargs...)
    if isnothing(libs)
        libs = load_libs(PAN_LIB_PATH)
    end
    cmd = string(name, " alter param=\"", param, "\" value=", value)
    for (key,value) in kwargs
        cmd = string(cmd, " ", key, "=", value)
    end
    exec_cmd(cmd, libs)
end


end
