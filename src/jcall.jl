
macro jimport(class)
    if isa(class, Expr)
        juliaclass=sprint(Base.show_unquoted, class)
    elseif isa(class, Symbol)
        juliaclass=string(class)
    elseif isa(class, String)
        juliaclass=class
    else
        error("Macro parameter is of type $(typeof(class))!!")
    end
    quote
        JavaObject{(Base.symbol($juliaclass))}
    end
end

function jnew(T::Symbol, argtypes::Tuple, args...)
    sig = method_signature(Void, argtypes...)
    jmethodId = ccall(jnifunc.GetMethodID, Ptr{Void}, (Ptr{JNIEnv}, Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}), penv, metaclass(T), utf8("<init>"), sig)
    if (jmethodId == C_NULL)
        error("No constructor for $T with signature $sig")
    end
    return  _jcall(metaclass(T), jmethodId, jnifunc.NewObjectA, JavaObject{T}, argtypes, args...)
end


@memoize function metaclass(class::Symbol)
    jclass=javaclassname(class)
    jclassptr = ccall(jnifunc.FindClass, Ptr{Void}, (Ptr{JNIEnv}, Ptr{Uint8}), penv, jclass)
    if jclassptr == C_NULL; error("Class Not Found $jclass"); end
    return JavaMetaClass(class, jclassptr)
end

metaclass{T}(::Type{JavaObject{T}}) = metaclass(T)
metaclass{T}(::JavaObject{T}) = metaclass(T)

javaclassname(class::Symbol) = utf8(replace(string(class), '.', '/'))

function geterror(allow=false)
    isexception = ccall(jnifunc.ExceptionCheck, jboolean, (Ptr{JNIEnv},), penv )
    
    if isexception == JNI_TRUE
        jthrow = ccall(jnifunc.ExceptionOccurred, Ptr{Void}, (Ptr{JNIEnv},), penv)
        if jthrow==C_NULL ; error ("Java Exception thrown, but no details could be retrieved from the JVM"); end
        ccall(jnifunc.ExceptionDescribe, Void, (Ptr{JNIEnv},), penv ) #Print java stackstrace to stdout
        ccall(jnifunc.ExceptionClear, Void, (Ptr{JNIEnv},), penv )
        jclass = ccall(jnifunc.FindClass, Ptr{Void}, (Ptr{JNIEnv},Ptr{Uint8}), penv, "java/lang/Throwable")
        if jclass==C_NULL; error("Java Exception thrown, but no details could be retrieved from the JVM"); end
        jmethodId=ccall(jnifunc.GetMethodID, Ptr{Void}, (Ptr{JNIEnv}, Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}), penv, jclass, "toString", "()Ljava/lang/String;")
        if jmethodId==C_NULL; error("Java Exception thrown, but no details could be retrieved from the JVM"); end
        res = ccall(jnifunc.CallObjectMethodA, Ptr{Void}, (Ptr{JNIEnv}, Ptr{Void}, Ptr{Void}, Ptr{Void}), penv, jthrow, jmethodId,C_NULL)
        if res==C_NULL; error("Java Exception thrown, but no details could be retrieved from the JVM"); end
        msg = bytestring(JString(res))
        ccall(jnifunc.DeleteLocalRef, Void, (Ptr{JNIEnv}, Ptr{Void}), penv, jthrow)
        error(string("Error calling Java: ",msg))
    else
        if allow==false
            return #No exception pending, legitimate NULL returned from Java
        else
            error("Null from Java. Not known how")
        end
    end
end

# Call static methods
function jcall{T}(typ::Type{JavaObject{T}}, method::String, rettype::Type, argtypes::Tuple, args... )
    try
        gc_enable(false)
        sig = method_signature(rettype, argtypes...)
        
        jmethodId = ccall(jnifunc.GetStaticMethodID, Ptr{Void}, (Ptr{JNIEnv}, Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}), penv, metaclass(T), utf8(method), sig)
        if jmethodId==C_NULL; geterror(true); end
        
        _jcall(metaclass(T), jmethodId, C_NULL, rettype, argtypes, args...)
    finally
        gc_enable(true)
    end
    
end

# Call instance methods
function jcall(obj::JavaObject, method::String, rettype::Type, argtypes::Tuple, args... )
    try
        gc_enable(false)
        sig = method_signature(rettype, argtypes...)
        jmethodId = ccall(jnifunc.GetMethodID, Ptr{Void}, (Ptr{JNIEnv}, Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}), penv, metaclass(obj), utf8(method), sig)
        if jmethodId==C_NULL; geterror(true); end
        _jcall(obj, jmethodId, C_NULL, rettype,  argtypes, args...)
    finally
        gc_enable(true)
    end
end



#Generate these methods to satisfy ccall's compile time constant requirement
#_jcall for primitive and Void return types
for (x, y, z) in [ (:jboolean, :(jnifunc.CallBooleanMethodA), :(jnifunc.CallStaticBooleanMethodA)),
                  (:jchar, :(jnifunc.CallCharMethodA), :(jnifunc.CallStaticCharMethodA)),
                  (:jbyte, :(jnifunc.CallByteMethodA), :(jnifunc.CallStaticByteMethodA)),
                  (:jshort, :(jnifunc.CallShortMethodA), :(jnifunc.CallStaticShortMethodA)),
                  (:jint, :(jnifunc.CallIntMethodA), :(jnifunc.CallStaticIntMethodA)),
                  (:jlong, :(jnifunc.CallLongMethodA), :(jnifunc.CallStaticLongMethodA)),
                  (:jfloat, :(jnifunc.CallFloatMethodA), :(jnifunc.CallStaticFloatMethodA)),
                  (:jdouble, :(jnifunc.CallDoubleMethodA), :(jnifunc.CallStaticDoubleMethodA)),
                  (:Void, :(jnifunc.CallVoidMethodA), :(jnifunc.CallStaticVoidMethodA)) ]
    m = quote
        function _jcall(obj,  jmethodId::Ptr{Void}, callmethod::Ptr{Void}, rettype::Type{$(x)}, argtypes::Tuple, args... )
            if callmethod == C_NULL #!
                callmethod = ifelse( typeof(obj)<:JavaObject, $y , $z )
            end
            @assert callmethod != C_NULL
            @assert jmethodId != C_NULL
            if(isnull(obj)); error("Attempt to call method on Java NULL"); end
            savedArgs, convertedArgs = convert_args(argtypes, args...)
            result = ccall(callmethod, $x , (Ptr{JNIEnv}, Ptr{Void}, Ptr{Void}, Ptr{Void}), penv, obj.ptr, jmethodId, convertedArgs)
            if result==C_NULL; geterror(); end
            if result == nothing; return; end
            return convert_result(rettype, result)
        end
    end
    eval(m)
end

#_jcall for Object return types
#obj -- reciever - Class pointer or object prointer
#jmethodId -- Java method ID
#callmethod -- the C method pointer to call
function _jcall(obj,  jmethodId::Ptr{Void}, callmethod::Ptr{Void}, rettype::Type, argtypes::Tuple, args... )
    if callmethod == C_NULL
        callmethod = ifelse( typeof(obj)<:JavaObject, jnifunc.CallObjectMethodA , jnifunc.CallStaticObjectMethodA )
    end
    @assert callmethod != C_NULL
    @assert jmethodId != C_NULL
    if(isnull(obj)); error("Attempt to call method on Java NULL"); end
    savedArgs, convertedArgs = convert_args(argtypes, args...)
    result = ccall(callmethod, Ptr{Void} , (Ptr{JNIEnv}, Ptr{Void}, Ptr{Void}, Ptr{Void}), penv, obj.ptr, jmethodId, convertedArgs)
    if result==C_NULL; geterror(); end
    return convert_result(rettype, result)
end


#get the JNI signature string for a method, given its
#return type and argument types
function method_signature(rettype, argtypes...)
    s=IOBuffer()
    write(s, "(")
    for arg in argtypes
        write(s, signature(arg))
    end
    write(s, ")")
    write(s, signature(rettype))
    return takebuf_string(s)
end


#get the JNI signature string for a given type
function signature(arg::Type)
    if is(arg, jboolean)
        return "Z"
    elseif is(arg, jbyte)
        return "B"
    elseif is(arg, jchar)
        return "C"
    elseif is(arg, jint)
        return "I"
    elseif is(arg, jlong)
        return "J"
    elseif is(arg, jfloat)
        return "F"
    elseif is(arg, jdouble)
        return "D"
    elseif is(arg, Void)
        return "V"
    elseif issubtype(arg, Array)
        return string("[", signature(eltype(arg)))
    end
end

signature{T}(arg::Type{JavaObject{T}}) = string("L", javaclassname(T), ";")
