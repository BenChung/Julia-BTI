#TODO: function readline(???)
#TODO: function writeall(Cmd, String)
#TODO: cleanup methods duplicated with io.jl
#TODO: fix examples in manual (run return value, STDIO parameters, const first, dup)
#TODO: remove ProcessStatus if not used
#TODO: allow waiting on handles other than processes
#TODO: don't allow waiting on close'd handles
#TODO: libuv process_events w/o blocking
#TODO: implement various buffer modes and helper function (minor)


typealias PtrSize Int
const IOStreamHandle = Ptr{Void}
globalEventLoop() = ccall(:jl_global_event_loop,Ptr{Void},())
mkNewEventLoop() = ccall(:jl_new_event_loop,Ptr{Void},())

typealias Executable Union(Vector{ByteString},Function)
typealias Callback Union(Function,Bool)

abstract AsyncStream <: Stream
typealias StreamOrNot Union(Bool,AsyncStream)
typealias BufOrNot Union(Bool,IOStream)
typealias UVHandle Ptr{Void}
typealias RawOrBoxedHandle Union(UVHandle,AsyncStream)
typealias StdIOSet (RawOrBoxedHandle, RawOrBoxedHandle, RawOrBoxedHandle)

const _sizeof_uv_pipe = ccall(:jl_sizeof_uv_pipe_t,Int32,())

abstract AbstractCmd

type Cmd <: AbstractCmd
    exec::Executable
    ignorestatus::Bool
    Cmd(exec::Executable) = new(exec,false)
end

type OrCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    OrCmds(a::AbstractCmd, b::AbstractCmd) = new(a,b)
end

type AndCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    AndCmds(a::AbstractCmd, b::AbstractCmd) = new(a,b)
end

ignorestatus(cmd::Cmd) = (cmd.ignorestatus=true; cmd)
ignorestatus(cmd::Union(OrCmds,AndCmds)) = (ignorestatus(cmd.a); ignorestatus(cmd.b); cmd)

#typealias StreamHandle Union(PtrSize,AsyncStream)

type Process
    cmd::Cmd
    handle::Ptr{Void}
    in::AsyncStream
    out::AsyncStream
    err::AsyncStream
    exit_code::Int32
    term_signal::Int32
    exitcb::Callback
    closecb::Callback
    function Process(cmd::Cmd,handle::Ptr{Void},in::RawOrBoxedHandle,out::RawOrBoxedHandle,err::RawOrBoxedHandle)
    if(!isa(in,AsyncStream))
        in=null_handle
    end
    if(!isa(out,AsyncStream))
        out=null_handle
    end
    if(!isa(err,AsyncStream))
        err=null_handle
    end
    new(cmd,handle,in,out,err,-2,-2,false,false)
    end
end

type ProcessChain
    processes::Vector{Process}
    in::StreamOrNot
    out::StreamOrNot
    err::StreamOrNot
    ProcessChain(stdios::StdIOSet) = new(Process[],stdios[1],stdios[2],stdios[3])
end
typealias ProcessChainOrNot Union(Bool,ProcessChain)

const _jl_wait_for = Union(Process,)[]
function _jl_wait_for_(p::Process)
    if !process_exited(p)
        push(_jl_wait_for, p)
    end
end
_jl_wait_for_(pc::ProcessChain) = map(_jl_wait_for_, pc.processes)

type NamedPipe <: AsyncStream
    handle::Ptr{Void}
    buffer::Buffer
    closed::Bool
    readcb::Callback
	closecb::Callback
    NamedPipe() = new(C_NULL,DynamicBuffer(),false,false,false)
end

type TTY <: AsyncStream
    handle::Ptr{Void}
    closed::Bool
    buffer::Buffer
    readcb::Callback
	closecb::Callback
    TTY(handle,closed)=new(handle,closed,DynamicBuffer(),false,false)
end

abstract Socket <: AsyncStream

type TcpSocket <: Socket
    handle::Ptr{Void}
	closed::Bool
    buffer::Buffer
    readcb::Callback
	ccb::Callback
	closecb::Callback
    TcpSocket(handle,closed)=new(handle,closed,DynamicBuffer(),false,false,false)
	function TcpSocket()
		this = TcpSocket(C_NULL,false)
		this.handle = ccall(:jl_make_tcp,Ptr{Void},(Ptr{Void},TcpSocket),globalEventLoop(),this)
		if(this.handle == C_NULL)
			error("Failed to start reading: ",_uv_lasterror(globalEventLoop()))
		end
		this
	end
end

type UdpSocket <: Socket
    handle::Ptr{Void}
	closed::Bool
    buffer::Buffer
    readcb::Callback
	ccb::Callback
	closecb::Callback
    UdpSocket(handle,closed)=new(handle,closed,DynamicBuffer(),false)
	function UdpSocket()
		this = UdpSocket(C_NULL,false)
		this.handle = ccall(:jl_make_tcp,Ptr{Void},(Ptr{Void},UdpSocket),globalEventLoop(),this)
		this
	end
end

copy(s::TTY) = TTY(s.handle,s.closed)

#SpawnNullStream is Singleton
type SpawnNullStream <: AsyncStream
end

const null_handle = SpawnNullStream()
SpawnNullStream() = null_handle

copy(s::SpawnNullStream) = s

convert(T::Type{Ptr{Void}}, s::AsyncStream) = convert(T, s.handle)
read_handle(s::AsyncStream) = s.handle
write_handle(s::AsyncStream) = s.handle
read_handle(s::Bool) = s ? error("read_handle: invalid value") : C_NULL
write_handle(s::Bool) = s ? error("write_handle: invalid value") : C_NULL
read_handle(::SpawnNullStream) = C_NULL
write_handle(::SpawnNullStream) = C_NULL
read_handle(s::Ptr{Void}) = s
write_handle(s::Ptr{Void}) = s

make_stdout_stream() = _uv_tty2tty(ccall(:jl_stdout_stream, Ptr{Void}, ()))

function _uv_tty2tty(handle::Ptr{Void})
    tty = TTY(handle,false)
    ccall(:jl_uv_associate_julia_struct,Void,(Ptr{Void},TTY),handle,tty)
    tty
end

#macro init_stdio()
#begin
    const STDIN  = _uv_tty2tty(ccall(:jl_stdin_stream ,Ptr{Void},()))
    const STDOUT = _uv_tty2tty(ccall(:jl_stdout_stream,Ptr{Void},()))
    const STDERR = _uv_tty2tty(ccall(:jl_stderr_stream,Ptr{Void},()))
    const stdin_stream  = STDIN
    const stdout_stream = STDOUT
    const stderr_stream = STDERR
    OUTPUT_STREAM = STDOUT
#end
#end

#@init_stdio

## SOCKETS ##

function _init_buf(stream::AsyncStream)
    if(!isa(stream.buf,IOStream))
        stream.buf=memio()
    end
end

_jl_tcp_init(loop::Ptr{Void}) = ccall(:jl_tcp_init,Ptr{Void},(Ptr{Void},),loop)
_jl_udp_init(loop::Ptr{Void}) = ccall(:jl_udp_init,Ptr{Void},(Ptr{Void},),loop)

abstract IpAddr

type Ip4Addr <: IpAddr
    port::Uint16
    host::Uint32
end

type Ip6Addr <: IpAddr
    port::Uint16
    host::Array{Uint8,1} #this should be fixed at 16 bytes is fixed size arrays are implemented
    flow_info::Uint32
    scope::Uint32
end

_uv_hook_connectioncb(sock::AsyncStream, status::Int32) = sock.ccb(sock,status)

function _jl_listen(sock::AsyncStream,backlog::Int32,cb::Function)
    sock.ccb = cb
	ccall(:jl_listen,Int32,(Ptr{Void},Int32),sock.handle,backlog)
end

_jl_tcp_bind(sock::TcpSocket,addr::Ip4Addr) = ccall(:jl_tcp_bind,Int32,(Ptr{Void},Uint32,Uint16),sock.handle,hton(addr.port),addr.host)
_jl_tcp_connect(sock::TcpSocket,addr::Ip4Addr) = ccall(:jl_tcp_connect,Int32,(Ptr{Void},Uint32,Uint16,Function),sock.handle,addr.host,hton(addr.port))
_jl_tcp_accept(server::Ptr,client::Ptr) = ccall(:uv_accept,Int32,(Ptr{Void},Ptr{Void}),server,client)
accept(server::TcpSocket,client::TcpSocket) = _jl_tcp_accept(server.handle,client.handle)


function open_any_tcp_port(preferred_port::Uint16,cb::Function)
    socket = TcpSocket();
    addr = Ip4Addr(preferred_port,uint32(0)) #bind prefereed port on all adresses
	while true
		if _jl_tcp_bind(socket,addr)!=0
		    error("open_any_tcp_port: could not bind to socket")
		end
		if((_jl_listen(socket,int32(4),cb)) == 0)
			break
		end
		addr.port+=1;
	end
    return (addr.port,socket)
end
open_any_tcp_port(preferred_port::Integer,cb::Function)=open_any_tcp_port(uint16(preferred_port),cb)

## BUFFER ##
## Allocate a simple buffer
function alloc_request(buffer::DynamicBuffer, recommended_size)
    if(length(buffer.data)-buffer.ptr<recommended_size)
        grow(buffer, recommended_size-length(buffer.data)+buffer.ptr)
    end
    return (pointer(buffer.data)+buffer.ptr-1, recommended_size)
end

function alloc_request(buffer::LineBuffer, recommended_size)
    if(length(buffer.data)-buffer.ptr<recommended_size)
        grow(buffer, recommended_size-length(buffer.data)+buffer.ptr)
    end
    return (pointer(buffer.data)+buffer.ptr-1, recommended_size)
end

function alloc_request(buffer::FixedBuffer, recommended_size)
    return (pointer(buffer.data)+buffer.ptr-1, length(buffer.data)-buffer.ptr)
end

_uv_hook_alloc_buf(stream::AsyncStream, recommended_size::Int32) = alloc_request(stream.buffer,recommended_size)


function notify_filled(buffer::DynamicBuffer, nread::Int, base::Ptr, len::Int32)
    buffer.ptr+=nread
    true
end
function notify_filled(buffer::FixedBuffer, nread::Int, base::Ptr, len::Int32)
    buffer.ptr+=nread
    true
end
function notify_filled(buffer::LineBuffer, nread::Int, base::Ptr, len::Int32)
    pos = memchr(buffer.data,'\n',buffer.ptr)
    if(pos == 0)
        return false
    end
    buffer.nlpos = pos
    buffer.ptr+=nread
    true
end
notify_content_accepted(buffer::DynamicBuffer) = nothing #Buffer conent management is left to the user
notify_content_accepted(buffer::FixedBuffer) = nothing #Buffer conent management is left to the user
function notify_content_accepted(buffer::LineBuffer)
    len = buffer.ptr - buffer.nlpos
    if(len > 0)
        copy_to(buffer.data,1,buffer.data,buffer.nlpos,len)
    end
    buffer.ptr = len+1
    buffer.nlpos = 0
end

function _uv_hook_readcb(stream::AsyncStream,nread::Int, base::Ptr, len::Int32)
    if(nread == -1)
		close(stream)
		if(isa(stream.closecb,Function))
			stream.closecb()
		end
        if(_uv_lasterror(globalEventLoop()) != 1) #UV_EOF == 1
            error("Failed to start reading: ",_uv_lasterror(globalEventLoop()))
        end
        #EOF
    else
        if(notify_filled(stream.buffer,nread,base,len) && isa(stream.readcb,Function))
            if(stream.readcb(stream))
                notify_content_accepted(stream.buffer)#,nread,base,len)
            end
        end
    end
end
##########################################
# Async Workers
##########################################

abstract AsyncWork

type SingleAsyncWork <: AsyncWork
    cb::Function
    handle::Ptr{Void}
    function SingleAsyncWork(loop::Ptr{Void},cb::Function)
        if(loop == C_NULL)
            return new(cb,C_NULL)
        end
        this=new(cb)
        this.handle=ccall(:jl_make_async,Ptr{Void},(Ptr{Void},SingleAsyncWork),loop,this)
        this
    end
end

type IdleAsyncWork <: AsyncWork
    cb::Function
    handle::Ptr{Void}
    function IdleAsyncWork(loop::Ptr{Void},cb::Function)
        this=new(cb)
        this.handle=ccall(:jl_make_idle,Ptr{Void},(Ptr{Void},IdleAsyncWork),loop,this)
        this
    end
end

type TimeoutAsyncWork <: AsyncWork
    cb::Function
    handle::Ptr{Void}
    function TimeoutAsyncWork(loop::Ptr{Void},cb::Function)
        this=new(cb)
        this.handle=ccall(:jl_make_timer,Ptr{Void},(Ptr{Void},TimeoutAsyncWork),loop,this)
        this
    end
end

const dummySingleAsync = SingleAsyncWork(C_NULL,()->nothing)

_uv_hook_close(uv::AsyncStream) = uv.closed = true
_uv_hook_close(uv::AsyncWork) = nothing

# This serves as a common callback for all async classes
_uv_hook_asynccb(async::AsyncWork, status::Int32) = async.cb(status)

function startTimer(timer::TimeoutAsyncWork,timeout::Int64,repeat::Int64)
    ccall(:jl_timer_start,Int32,(Ptr{Void},Int64,Int64),timer.handle,timeout,repeat)
end

function stopTimer(timer::TimeoutAsyncWork)
    ccall(:jl_timer_stop,Int32,(Ptr{Void},),timer.handle)
end

assignIdleAsyncWork(work::IdleAsyncWork,cb::Function) = ccall(:jl_idle_start,Ptr{Void},(Ptr{Void},),work.handle)

function add_idle_cb(loop::Ptr{Void},cb::Function)
    work = initIdleAsyncWork(loop)
    assignIdleAsyncWork(work,cb)
    work
end

function queueAsync(work::SingleAsyncWork)
    ccall(:jl_async_send,Void,(Ptr{Void},),work.handle)
end

# process status #
abstract ProcessStatus
type ProcessNotRun   <: ProcessStatus; end
type ProcessRunning  <: ProcessStatus; end
type ProcessExited   <: ProcessStatus; status::PtrSize; end
type ProcessSignaled <: ProcessStatus; signal::PtrSize; end
type ProcessStopped  <: ProcessStatus; signal::PtrSize; end

process_exited  (s::Process) = (s.exit_code != -2)
process_signaled(s::Process) = (s.term_signal > 0)
process_stopped (s::Process) = 0 #not supported by libuv. Do we need this?

process_exit_status(s::Process) = s.exit_code
process_term_signal(s::Process) = s.term_signal
process_stop_signal(s::Process) = 0 #not supported by libuv. Do we need this?

function process_status(s::PtrSize)
    process_exited  (s) ? ProcessExited  (process_exit_status(s)) :
    process_signaled(s) ? ProcessSignaled(process_term_signal(s)) :
    process_stopped (s) ? ProcessStopped (process_stop_signal(s)) :
    error("process status error")
end

## types

##event loop
function run_event_loop(loop::Ptr{Void})
    ccall(:jl_run_event_loop,Void,(Ptr{Void},),loop)
end
run_event_loop() = run_event_loop(globalEventLoop())

function break_one_loop(loop::Ptr{Void})
    ccall(:uv_break_one,Void,(Ptr{Void},),loop)
end
break_one_loop() = break_one_loop(globalEventLoop())

function process_events(loop::Ptr{Void})
    ccall(:jl_process_events,Void,(Ptr{Void},),loop)
end
process_events() = process_events(globalEventLoop())

##pipe functions
malloc_pipe() = _c_malloc(_sizeof_uv_pipe)
function link_pipe(read_end::Ptr{Void},readable_julia_only::Bool,write_end::Ptr{Void},writeable_julia_only::Bool,pipe::AsyncStream)
    #make the pipe an unbuffered stream for now
    ccall(:jl_init_pipe, Ptr{Void}, (Ptr{Void},Bool,Bool,AsyncStream), read_end, 0, readable_julia_only, pipe)
    ccall(:jl_init_pipe, Ptr{Void}, (Ptr{Void},Bool,Bool,AsyncStream), write_end, 1, readable_julia_only, pipe)
    error = ccall(:uv_pipe_link, Int, (Ptr{Void}, Ptr{Void}), read_end, write_end)
    if error != 0 # don't use assert here as $string isn't be defined yet
        error("uv_pipe_link failed")
    end
end

function link_pipe(read_end2::NamedPipe,readable_julia_only::Bool,write_end::Ptr{Void},writeable_julia_only::Bool)
    if(read_end2.handle == C_NULL)
        read_end2.handle = malloc_pipe()
    end
    link_pipe(read_end2.handle,readable_julia_only,write_end,writeable_julia_only,read_end2)
end
function link_pipe(read_end::Ptr{Void},readable_julia_only::Bool,write_end::NamedPipe,writeable_julia_only::Bool)
    if(write_end.handle == C_NULL)
        write_end.handle = malloc_pipe()
    end
    link_pipe(read_end,readable_julia_only,write_end.handle,writeable_julia_only,write_end)
end
close_pipe_sync(handle::UVHandle) = ccall(:uv_pipe_close_sync,Void,(UVHandle,),handle)

function close(stream::AsyncStream)
    if(!stream.closed)
        ccall(:jl_close_uv,Void,(Ptr{Void},),stream.handle)
        stream.closed=true
    end
end

##stream functions

start_reading(stream::AsyncStream) = ccall(:jl_start_reading,Int32,(Ptr{Void},),read_handle(stream))
start_reading(stream::AsyncStream,cb::Function) = (start_reading(stream);stream.readcb=cb)
start_reading(stream::AsyncStream,cb::Bool) = ccall(:jl_start_reading,Bool,(Ptr{Void},),read_handle(stream))

stop_reading(stream::AsyncStream) = ccall(:uv_read_stop,Bool,(Ptr{Void},),read_handle(stream))
change_readcb(stream::AsyncStream,readcb::Function) = ccall(:jl_change_readcb,Int16,(Ptr{Void},Function),read_handle(stream),readcb)

function readall(stream::AsyncStream)
    start_reading(stream)
    run_event_loop()
    return takebuf_string(stream.buf)
end

show(io, p::Process) = print(io, "Process(", p.cmd, ")")

function finish_read(pipe::NamedPipe)
    close(pipe) #handles to UV and ios will be invalid after this point
end

function finish_read(state::(NamedPipe,ByteString))
    finish_read(state...)
end

function end_process(p::Process,h::Ptr{Void},e::Int32, t::Int32)
    p.exit_code=e
    p.term_signal=t
end

function _jl_spawn(cmd::Ptr{Uint8}, argv::Ptr{Ptr{Uint8}}, loop::Ptr{Void}, pp::Process,
        in::Ptr{Void}, out::Ptr{Void}, err::Ptr{Void})
    return ccall(:jl_spawn, PtrSize,
        (Ptr{Uint8}, Ptr{Ptr{Uint8}}, Ptr{Void}, Process, Ptr{Void}, Ptr{Void}, Ptr{Void}),
         cmd,        argv,            loop,      pp,       in,        out,       err)
end

function _uv_hook_return_spawn(proc::Process, exit_status::Int32, term_signal::Int32)
    if proc.exitcb == false || !isa(proc.exitcb(proc,exit_status,term_signal), Nothing)
        process_exited_chain(proc,exit_status,term_signal)
    end
end

function _uv_hook_close(proc::Process)
    if proc.closecb == false || !isa(proc.exitcb(pp,args...), Nothing)
        process_closed_chain(proc)
    end
end

function spawn(pc::ProcessChainOrNot,cmd::Cmd,stdios::StdIOSet,exitcb::Callback,closecb::Callback)
    loop = globalEventLoop()
    close_in,close_out,close_err = false,false,false
    if(isa(stdios[1],NamedPipe)&&stdios[1].handle==C_NULL)
        in = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
        #in = _c_malloc(_sizeof_uv_pipe)
        link_pipe(in,false,stdios[1],true)
        close_in = true
    else
        in = read_handle(stdios[1])
    end
    if(isa(stdios[2],NamedPipe)&&stdios[2].handle==C_NULL)
        out = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
        #out = _c_malloc(_sizeof_uv_pipe)
        link_pipe(stdios[2],false,out,true)
        close_out = true
    else
        out = write_handle(stdios[2])
    end
    if(isa(stdios[3],NamedPipe)&&stdios[3].handle==C_NULL)
        err = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
        #err = _c_malloc(_sizof_uv_pipe)
        link_pipe(stdios[3],false,err,true)
        close_err = true
    else
        err = write_handle(stdios[3])
    end
    pp = Process(cmd,C_NULL,stdios[1],stdios[2],stdios[3]);
    ptrs = _jl_pre_exec(cmd.exec)
    pp.exitcb = exitcb
    pp.closecb = closecb
    pp.handle=_jl_spawn(ptrs[1], convert(Ptr{Ptr{Uint8}}, ptrs), loop, pp,
        in,out,err)
    if pc != false
        push(pc.processes, pp)
    end
    if(close_in)
        close_pipe_sync(in)
        #_c_free(in)
    end
    if(close_out)
        close_pipe_sync(out)
        #_c_free(out)
    end
    if(close_err)
        close_pipe_sync(err)
        #_c_free(err)
    end
    pp
end

function process_exited_chain(p::Process,e::Int32,t::Int32)
    p.exit_code = e
    p.term_signal = t
    true
end

function process_closed_chain(p::Process)
    done = process_exited(p)
    i = findfirst(_jl_wait_for, p)
    if i > 0
        del(_jl_wait_for, i)
        if length(_jl_wait_for) == 0
            break_one_loop()
        end
    end
    done
end

function spawn(pc::ProcessChainOrNot,cmds::OrCmds,stdios::StdIOSet,exitcb::Callback,closecb::Callback)
    out_pipe = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
    in_pipe = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
    #out_pipe = _c_malloc(_sizeof_uv_pipe)
    #in_pipe = _c_malloc(_sizeof_uv_pipe)
    link_pipe(in_pipe,false,out_pipe,false,null_handle)
    if pc == false
        pc = ProcessChain(stdios)
    end
    try
        spawn(pc, cmds.a, (stdios[1], out_pipe, stdios[3]), exitcb, closecb)
        spawn(pc, cmds.b, (in_pipe, stdios[2], stdios[3]), exitcb, closecb)
    catch e
        close_pipe_sync(out_pipe)
        close_pipe_sync(in_pipe)
        throw(e)
    end
    close_pipe_sync(out_pipe)
    close_pipe_sync(in_pipe)
    pc
end

function spawn(pc::ProcessChainOrNot,cmds::AndCmds,stdios::StdIOSet,exitcb::Callback,closecb::Callback)
    if pc == false
        pc = ProcessChain(stdios)
    end
    close_in,close_out,close_err = false,false,false
    if(isa(stdios[1],NamedPipe)&&stdios[1].handle==C_NULL)
        in = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
        #in = _c_malloc(_sizeof_uv_pipe)
        link_pipe(in,false,stdios[1],true)
        close_in = true
    else
        in = read_handle(stdios[1])
    end
    if(isa(stdios[2],NamedPipe)&&stdios[2].handle==C_NULL)
        out = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
        #out = _c_malloc(_sizeof_uv_pipe)
        link_pipe(stdios[2],false,out,true)
        close_out = true
    else
        out = write_handle(stdios[2])
    end
    if(isa(stdios[3],NamedPipe)&&stdios[3].handle==C_NULL)
        err = box(Ptr{Void},jl_alloca(unbox(Int32,_sizeof_uv_pipe)))
        #err = _c_malloc(_sizof_uv_pipe)
        link_pipe(stdios[3],false,err,true)
        close_err = true
    else
        err = write_handle(stdios[3])
    end
    spawn(pc, cmds.a, (in,out,err), exitcb, closecb)
    spawn(pc, cmds.b, (in,out,err), exitcb, closecb)
    if(close_in)
        close_pipe_sync(in)
        #_c_free(in)
    end
    if(close_out)
        close_pipe_sync(out)
        #_c_free(out)
    end
    if(close_err)
        close_pipe_sync(err)
        #_c_free(err)
    end
    pp
    pc
end

function reinit_stdio()
    STDIN.handle  = ccall(:jl_stdin_stream ,Ptr{Void},())
    STDOUT.handle = ccall(:jl_stdout_stream,Ptr{Void},())
    STDERR.handle = ccall(:jl_stderr_stream,Ptr{Void},())
    STDIN.buffer = DynamicBuffer()
    STDOUT.buffer = DynamicBuffer()
    STDERR.buffer = DynamicBuffer()
    for stream in (STDIN,STDOUT,STDERR)
        ccall(:jl_uv_associate_julia_struct,Void,(Ptr{Void},TTY),stream.handle,stream)
    end
end

# INTERNAL
# returns a touple of function arguments to spawn:
# (stdios, exitcb, closecb)
# |       |        \ The function to be called once the uv handle is closed
# |       \ The function to be called once the process exits
# \ A set of up to 256 stdio instructions, where each entry can be either:
#   | - An AsyncStream to be passed to the child
#   | - true: This will let the child inherit the parents' io (only valid for 0-2)
#   \ - false: None (for 3-255) or /dev/null (for 0-2)


for (sym, stdin, stdout, stderr) in {(:spawn_opts_inherit, STDIN,STDOUT,STDERR),
                       (:spawn_opts_swallow, null_handle,null_handle,null_handle)}
@eval begin
 ($sym)(stdios::StdIOSet,exitcb::Callback,closecb::Callback) = (stdios,exitcb,closecb)
 ($sym)(stdios::StdIOSet,exitcb::Callback) = (stdios,exitcb,false)
 ($sym)(stdios::StdIOSet) = (stdios,false,false)
 ($sym)() = (($stdin,$stdout,$stderr),false,false)
 ($sym)(in::StreamOrNot) = ((isa(in,AsyncStream)?in:$stdin,$stdout,$stderr),false,false)
 ($sym)(in::StreamOrNot,out::StreamOrNot) = ((isa(in,AsyncStream)?in:$stdin,isa(out,AsyncStream)?out:$stdout,$stderr),false,false)
end
end

spawn(pc::ProcessChainOrNot,cmds::AbstractCmd,args...) = spawn(pc,cmds,spawn_opts_swallow(args...)...)
spawn(cmds::AbstractCmd,args...) = spawn(false,cmds,spawn_opts_swallow(args...)...)

spawn_nostdin(pc::ProcessChainOrNot,cmd::AbstractCmd,out::StreamOrNot) = spawn(pc,cmd,(false,out,false),false,false)
spawn_nostdin(cmd::AbstractCmd,out::StreamOrNot) = spawn(false,cmd,(false,out,false),false,false)

#returns a pipe to read from the last command in the pipelines
read_from(cmds::AbstractCmd)=read_from(cmds, null_handle)
function read_from(cmds::AbstractCmd, stdin::AsyncStream)
    out = NamedPipe()
    processes = spawn(false, cmds, (stdin,out,null_handle))
    start_reading(out)
    (out, processes)
end

write_to(cmds::AbstractCmd) = write_to(cmds, null_handle)
function write_to(cmds::AbstractCmd, stdout::StreamOrNot)
    in = NamedPipe()
    processes = spawn(false, cmds, (in,stdout,false))
    (in, processes)
end

readall(cmd::AbstractCmd) = readall(cmd, null_handle)
function readall(cmd::AbstractCmd,stdin::AsyncStream)
    (out,pc)=read_from(cmd, stdin)
    if !wait(pc)
        pipeline_error(pc)
    end
    return takebuf_string(out.buffer)
end

function run(cmds::AbstractCmd,args...)
    ps = spawn(cmds,spawn_opts_inherit(args...)...)
    success = wait(ps)
    if success
        return true
    else
        return pipeline_error(ps)
    end
end

success(proc::Process) = (assert(process_exited(proc)); proc.exit_code==0)
success(procs::ProcessChain) = all(map(success, procs.processes))
success(cmd::AbstractCmd) = wait(spawn(cmd))

function pipeline_error(proc::Process)
    if !proc.cmd.ignorestatus
        error("failed process: ",proc," [",proc.exit_code,"]")
    end
    true
end
function pipeline_error(procs::ProcessChain)
    failed = Process[]
    for p = procs.processes
        if !success(p) && !p.cmd.ignorestatus
            push(failed, p)
        end
    end
    if numel(failed)==0 return true end
    if numel(failed)==1 pipeline_error(failed[1]) end
    msg = "failed processes:"
    for proc in failed
        msg = string(msg,"\n  ",proc," [",proc.exit_code,"]")
    end
    error(msg)
    return false
end

function exec(thunk::Function)
    try
        thunk()
    catch e
        show(e)
        exit(0xff)
    end
    exit(0)
end

function wait(procs::Union(Process,ProcessChain))
    assert(length(_jl_wait_for) == 0)
    _jl_wait_for_(procs)
    if length(_jl_wait_for) > 0
        try
            run_event_loop() #wait(procs)
        catch e
            kill(procs)
            del_all(_jl_wait_for)
            process_events() #join(procs)
            throw(e)
        end
        assert(length(_jl_wait_for) == 0)
    end
    return success(procs)
end

_jl_kill(p::Process,signum::Int32) = ccall(:uv_process_kill,Int32,(Ptr{Void},Int32),p.handle,signum)
function kill(p::Process,signum::Int32)
    if p.exit_code == -2
        _jl_kill(p, int32(9))
    end
end
kill(ps::ProcessChain) = map(kill, ps.processes)
kill(p::Process) = kill(p,int32(9))

function _contains_newline(bufptr::Ptr{Void},len::Int32)
    return (ccall(:memchr,Ptr{Uint8},(Ptr{Void},Int32,Uint),bufptr,'\n',len)!=C_NULL)
end

## process status ##

function _jl_pre_exec(args::Vector{ByteString})
    if length(args) < 1
        error("exec: too few words to exec")
    end
    ptrs = Array(Ptr{Uint8}, length(args)+1)
    for i = 1:length(args)
        ptrs[i] = args[i].data
    end
    ptrs[length(args)+1] = C_NULL
    return ptrs
end

## implementation of `cmd` syntax ##

arg_gen(x::String) = ByteString[x]
arg_gen(cmd::Cmd)  = cmd.exec

function arg_gen(head)
    if applicable(start,head)
        vals = ByteString[]
        for x in head
            push(vals,cstring(x))
        end
        return vals
    else
        return ByteString[cstring(head)]
    end
end

function arg_gen(head, tail...)
    head = arg_gen(head)
    tail = arg_gen(tail...)
    vals = ByteString[]
    for h = head, t = tail
        push(vals,cstring(strcat(h,t)))
    end
    vals
end

function cmd_gen(parsed)
    args = ByteString[]
    for arg in parsed
        append!(args,arg_gen(arg...))
    end
    Cmd(args)
end

macro cmd(str)
    :(cmd_gen($_jl_shell_parse(str)))
end

## low-level calls

write(s::AsyncStream, b::ASCIIString) =
    ccall(:jl_puts, Int32, (Ptr{Uint8},Ptr{Void}),b.data,write_handle(s))
write(s::AsyncStream, b::Uint8) =
    ccall(:jl_putc, Int32, (Uint8, Ptr{Void}), b, write_handle(s))
write(s::AsyncStream, c::Char) =
    ccall(:jl_pututf8, Int32, (Ptr{Void},Char), write_handle(s), c)
write{T<:BitsKind}(s::AsyncStream, a::Array{T}) = ccall(:jl_write, Uint,(Ptr{Void}, Ptr{Void}, Uint32),write_handle(s), a, uint(numel(a)*sizeof(T)))
write(s::AsyncStream, p::Ptr, nb::Integer) = ccall(:jl_write, Uint,(Ptr{Void}, Ptr{Void}, Uint),write_handle(s), p, uint(nb))
_write(s::AsyncStream, p::Ptr{Void}, nb::Integer) = ccall(:jl_write, Uint,(Ptr{Void}, Ptr{Void}, Uint),write_handle(s),p,uint(nb))

(&)(left::AbstractCmd,right::AbstractCmd) = AndCmds(left,right)
(|)(src::AbstractCmd,dest::AbstractCmd) = OrCmds(src,dest)

function show(io, cmd::Cmd)
    if isa(cmd.exec,Vector{ByteString})
        esc = shell_escape(cmd.exec...)
        print(io,'`')
        for c in esc
            if c == '`'
                print(io,'\\')
            end
            print(io,c)
        end
        print(io,'`')
    else
        print(io, cmd.exec)
    end
end

function show(io, cmds::OrCmds)
    if isa(cmds.a, AndCmds)
        print("(")
        show(io, cmds.a)
        print(")")
    else
        show(io, cmds.a)
    end
    print(" | ")
    if isa(cmds.b, AndCmds)
        print("(")
        show(io, cmds.b)
        print(")")
    else
        show(io, cmds.b)
    end
end

function show(io, cmds::AndCmds)
    if isa(cmds.a, OrCmds)
        print("(")
        show(io, cmds.a)
        print(")")
    else
        show(io, cmds.a)
    end
    print(" & ")
    if isa(cmds.b, OrCmds)
        print("(")
        show(io, cmds.b)
        print(")")
    else
        show(io, cmds.b)
    end
end

_jl_connect_raw(sock::TcpSocket,sockaddr::Ptr{Void},cb::Function) = ccall(:jl_connect_raw,Int32,(Ptr{Void},Ptr{Void},Function),sock.handle,sockaddr,cb)
_jl_getaddrinfo(loop::Ptr,host::ByteString,service::Ptr,cb::Function) = ccall(:jl_getaddrinfo,Int32,(Ptr{Void},Ptr{Uint8},Ptr{Uint8},Function),loop,host,service,cb)
_jl_sockaddr_from_addrinfo(addrinfo::Ptr) = ccall(:jl_sockaddr_from_addrinfo,Ptr{Void},(Ptr,),addrinfo)
_jl_sockaddr_set_port(ptr::Ptr{Void},port::Uint16) = ccall(:jl_sockaddr_set_port,Void,(Ptr{Void},Uint16),ptr,port)
_uv_lasterror(loop::Ptr{Void}) = ccall(:jl_last_errno,Int32,(Ptr{Void},),loop)

function connect_callback(sock::TcpSocket,status::Int32,breakLoop::Bool)
    if(status==-1)
        error("Socket connection failed: ",_uv_lasterror(globalEventLoop()))
    end
    sock.open=true;
    if(breakLoop)
        break_one_loop(globalEventLoop())
    end
end

function getaddrinfo_callback(breakLoop::Bool,sock::TcpSocket,status::Int32,port::Uint16,addrinfo_list::Ptr)
    if(status==-1)
        error("Name lookup failed")
    end
    sockaddr = _jl_sockaddr_from_addrinfo(addrinfo_list) #only use first entry of the list for now
    _jl_sockaddr_set_port(sockaddr,hton(port))
    err = _jl_connect_raw(sock,sockaddr,(req::Ptr,status::Int32)->connect_callback(sock,status,breakLoop))
    if(err != 0)
        error("Failed to connect to host")
    end
end

#function readuntil(s::IOStream, delim)
#    # TODO: faster versions that avoid the encoding check
#    ccall(:jl_readuntil, ByteString, (Ptr{Void}, Uint8), s.ios, delim)
#end
#readline(s::IOStream) = readuntil(s, uint8('\n'))

function readall(s::IOStream)
    dest = memio()
    ccall(:ios_copyall, Uint, (Ptr{Void}, Ptr{Void}), dest.ios, s.ios)
    takebuf_string(dest)
end

function connect_to_host(host::ByteString,port::Uint16)
    sock = TcpSocket(_jl_tcp_init(globalEventLoop()))
    err = _jl_getaddrinfo(globalEventLoop(),host,C_NULL,(addrinfo::Ptr,status::Int32)->getaddrinfo_callback(true,sock,status,port,addrinfo))
    if(err!=0)
        error("Failed to  initilize request to resolve hostname: ",host)
    end
    run_event_loop(globalEventLoop())
    return sock
end
