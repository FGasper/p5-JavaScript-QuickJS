#include <stdbool.h>

#include "easyxs/easyxs.h"

#include "quickjs/quickjs.h"
#include "quickjs/quickjs-libc.h"

#define PERL_NS_ROOT "JavaScript::QuickJS"

#define PERL_BOOLEAN_CLASS "Types::Serialiser::Boolean"

#define PQJS_JSOBJECT_CLASS PERL_NS_ROOT "::JSObject"
#define PQJS_FUNCTION_CLASS PERL_NS_ROOT "::Function"
#define PQJS_REGEXP_CLASS   PERL_NS_ROOT "::RegExp"
#define PQJS_DATE_CLASS     PERL_NS_ROOT "::Date"
#define PQJS_PROMISE_CLASS  PERL_NS_ROOT "::Promise"

typedef struct {
    JSContext *ctx;
    pid_t pid;
    bool added_std;
    bool added_os;
    bool added_helpers;
    char* module_base_path;
} perl_qjs_s;

typedef struct {
    JSContext *ctx;
    JSValue jsobj;
    pid_t pid;
} perl_qjs_jsobj_s;

typedef struct {
#ifdef MULTIPLICITY
    tTHX aTHX;
#endif
    SV** svs;
    U32 svs_count;
    U32 refcount;
    bool ran_js_std_init_handlers;
    JSValue regexp_jsvalue;
    JSValue date_jsvalue;
    JSValue promise_jsvalue;
} ctx_opaque_s;

const char* __jstype_name_back[] = {
    [JS_TAG_BIG_DECIMAL - JS_TAG_FIRST] = "big decimal",
    [JS_TAG_BIG_INT - JS_TAG_FIRST] = "big integer",
    [JS_TAG_BIG_FLOAT - JS_TAG_FIRST] = "big float",
    [JS_TAG_SYMBOL - JS_TAG_FIRST] = "symbol",
    [JS_TAG_MODULE - JS_TAG_FIRST] = "module",
    [JS_TAG_OBJECT - JS_TAG_FIRST] = "object",
    [JS_TAG_FLOAT64 - JS_TAG_FIRST] = "float64",

    /* Small hack to ensure we can always read: */
    [99] = NULL,
};

const char* const DATE_GETTER_FROM_IX[] = {
    "toString",
    "toUTCString",
    "toGMTString",
    "toISOString",
    "toDateString",
    "toTimeString",
    "toLocaleString",
    "toLocaleDateString",
    "toLocaleTimeString",
    "getTimezoneOffset",
    "getTime",
    "getFullYear",
    "getUTCFullYear",
    "getMonth",
    "getUTCMonth",
    "getDate",
    "getUTCDate",
    "getHours",
    "getUTCHours",
    "getMinutes",
    "getUTCMinutes",
    "getSeconds",
    "getUTCSeconds",
    "getMilliseconds",
    "getUTCMilliseconds",
    "getDay",
    "getUTCDay",
    "toJSON",
};

const char* const DATE_SETTER_FROM_IX[] = {
    "setTime",
    "setMilliseconds",
    "setUTCMilliseconds",
    "setSeconds",
    "setUTCSeconds",
    "setMinutes",
    "setUTCMinutes",
    "setHours",
    "setUTCHours",
    "setDate",
    "setUTCDate",
    "setMonth",
    "setUTCMonth",
    "setFullYear",
    "setUTCFullYear",
};

#if defined _WIN32 || defined __CYGWIN__
#   define PATH_SEPARATOR '\\'
#else
#   define PATH_SEPARATOR '/'
#endif

#define _jstype_name(typenum) __jstype_name_back[ typenum - JS_TAG_FIRST ]

static SV* _JSValue_to_SV (pTHX_ JSContext* ctx, JSValue jsval, SV** err_svp);

static inline SV* _JSValue_special_object_to_SV (pTHX_ JSContext* ctx, JSValue jsval, SV** err_svp, const char* class) {
    assert(!*err_svp);

    SV* sv = exs_new_structref(perl_qjs_jsobj_s, class);
    perl_qjs_jsobj_s* pqjs = exs_structref_ptr(sv);

    *pqjs = (perl_qjs_jsobj_s) {
        .ctx = ctx,
        .jsobj = JS_DupValue(ctx, jsval),
        .pid = getpid(),
    };

    ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);
    ctxdata->refcount++;

    return sv;
}

static inline SV* _JSValue_object_to_SV (pTHX_ JSContext* ctx, JSValue jsval, SV** err_svp) {
    assert(!*err_svp);

    JSPropertyEnum *tab_atom;
    uint32_t tab_atom_count;

    int propnameserr = JS_GetOwnPropertyNames(ctx, &tab_atom, &tab_atom_count, jsval, JS_GPN_STRING_MASK);

    PERL_UNUSED_VAR(propnameserr);
    assert(!propnameserr);

    HV* hv = newHV();

    for(int i = 0; i < tab_atom_count; i++) {
        JSValue key = JS_AtomToString(ctx, tab_atom[i].atom);
        STRLEN strlen;
        const char* keystr = JS_ToCStringLen(ctx, &strlen, key);

        JSValue value = JS_GetProperty(ctx, jsval, tab_atom[i].atom);

        SV* val_sv = _JSValue_to_SV(aTHX_ ctx, value, err_svp);

        if (val_sv) {
            hv_store(hv, keystr, -strlen, val_sv, 0);
        }

        JS_FreeCString(ctx, keystr);
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, value);
        JS_FreeAtom(ctx, tab_atom[i].atom);

        if (!val_sv) break;
    }

    js_free(ctx, tab_atom);

    if (*err_svp) {
        SvREFCNT_dec( (SV*) hv );
        return NULL;
    }

    return newRV_noinc((SV*) hv);
}

static inline SV* _JSValue_array_to_SV (pTHX_ JSContext* ctx, JSValue jsval, SV** err_svp) {
    JSValue jslen = JS_GetPropertyStr(ctx, jsval, "length");
    uint32_t len;
    JS_ToUint32(ctx, &len, jslen);
    JS_FreeValue(ctx, jslen);

    AV* av = newAV();

    if (len) {
        av_fill( av, len - 1 );
        for (uint32_t i=0; i<len; i++) {
            JSValue jsitem = JS_GetPropertyUint32(ctx, jsval, i);

            SV* val_sv = _JSValue_to_SV(aTHX_ ctx, jsitem, err_svp);

            if (val_sv) av_store( av, i, val_sv );

            JS_FreeValue(ctx, jsitem);

            if (!val_sv) break;
        }
    }

    if (*err_svp) {
        SvREFCNT_dec((SV*) av);
        return NULL;
    }

    return newRV_noinc((SV*) av);
}

/* NO JS exceptions allowed here! */
static SV* _JSValue_to_SV (pTHX_ JSContext* ctx, JSValue jsval, SV** err_svp) {
    assert(!*err_svp);

    SV* RETVAL;

    int tag = JS_VALUE_GET_NORM_TAG(jsval);

    assert(tag != JS_TAG_EXCEPTION);

    switch (tag) {
        case JS_TAG_STRING:
            STMT_START {
                STRLEN strlen;
                const char* str = JS_ToCStringLen(ctx, &strlen, jsval);
                RETVAL = newSVpvn_flags(str, strlen, SVf_UTF8);
                JS_FreeCString(ctx, str);
            } STMT_END;
            break;

        case JS_TAG_INT:
            RETVAL = newSViv(JS_VALUE_GET_INT(jsval));
            break;

        case JS_TAG_FLOAT64:
            RETVAL = newSVnv(JS_VALUE_GET_FLOAT64(jsval));
            break;

        case JS_TAG_BOOL:
            RETVAL = boolSV(JS_VALUE_GET_BOOL(jsval));
            break;

        case JS_TAG_NULL:
        case JS_TAG_UNDEFINED:
            RETVAL = &PL_sv_undef;
            break;

        case JS_TAG_OBJECT:
            if (JS_IsFunction(ctx, jsval)) {
                load_module(
                    PERL_LOADMOD_NOIMPORT,
                    newSVpvs(PQJS_FUNCTION_CLASS),
                    NULL
                );

                SV* func_sv = exs_new_structref(perl_qjs_jsobj_s, PQJS_FUNCTION_CLASS);
                perl_qjs_jsobj_s* pqjs = exs_structref_ptr(func_sv);

                *pqjs = (perl_qjs_jsobj_s) {
                    .ctx = ctx,
                    .jsobj = JS_DupValue(ctx, jsval),
                    .pid = getpid(),
                };

                ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);
                ctxdata->refcount++;

                RETVAL = func_sv;
            }
            else if (JS_IsArray(ctx, jsval)) {
                RETVAL = _JSValue_array_to_SV(aTHX_ ctx, jsval, err_svp);
            }
            else {

                ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);

                if (JS_IsInstanceOf(ctx, jsval, ctxdata->regexp_jsvalue)) {
                    RETVAL = _JSValue_special_object_to_SV(aTHX_ ctx, jsval, err_svp, PQJS_REGEXP_CLASS);
                }
                else if (JS_IsInstanceOf(ctx, jsval, ctxdata->date_jsvalue)) {
                    RETVAL = _JSValue_special_object_to_SV(aTHX_ ctx, jsval, err_svp, PQJS_DATE_CLASS);
                }
                else if (JS_IsInstanceOf(ctx, jsval, ctxdata->promise_jsvalue)) {
                    RETVAL = _JSValue_special_object_to_SV(aTHX_ ctx, jsval, err_svp, PQJS_PROMISE_CLASS);
                }
                else {
                    RETVAL = _JSValue_object_to_SV(aTHX_ ctx, jsval, err_svp);
                }
            }

            break;

        default:
            STMT_START {
                const char* typename = _jstype_name(tag);

                if (typename) {
                    *err_svp = newSVpvf("Cannot convert JS %s (QuickJS tag %d) to Perl!", typename, tag);
                }
                else {
                    *err_svp = newSVpvf("Cannot convert (unexpected) JS tag value %d to Perl!", tag);
                }

                return NULL;
            } STMT_END;
    }

    return RETVAL;
}

static inline void _ctx_add_sv(pTHX_ JSContext* ctx, SV* sv) {
    ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);

    ctxdata->svs_count++;

    if (ctxdata->svs_count == 1) {
        Newx(ctxdata->svs, ctxdata->svs_count, SV*);
    }
    else {
        Renew(ctxdata->svs, ctxdata->svs_count, SV*);
    }

    ctxdata->svs[ctxdata->svs_count - 1] = SvREFCNT_inc(sv);
}

static JSValue _sv_to_jsvalue(pTHX_ JSContext* ctx, SV* value, SV** error);

#define _MAX_ERRSV_TO_JS_TRIES 10

/* Kind of like _sv_to_jsvalue(), but we need to handle the case where
   the error SV’s own conversion to a JSValue fails. In that case, we
   warn on the 1st error, then propagate the 2nd. Repeat until there are
   no errors.
*/
static JSValue _sv_error_to_jsvalue(pTHX_ JSContext* ctx, SV* error) {
    SV* error2 = NULL;

    uint32_t tries = 0;

    JSValue to_js;

    while (1) {
        to_js = _sv_to_jsvalue(aTHX_ ctx, error, &error2);

        if (!error2) break;

        warn_sv(error);

        tries++;
        if (tries > _MAX_ERRSV_TO_JS_TRIES) {
            warn_sv(error2);
            return JS_NewString(ctx, "Failed to convert Perl error to JavaScript after " STRINGIFY(_MAX_ERRSV_TO_JS_TRIES) " tries!");
        }

        error = error2;
        error2 = NULL;
    }

    return to_js;
}

static JSValue __do_perl_callback(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int jsmagic, JSValue *func_data) {

#ifdef MULTIPLICITY
    ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);
    pTHX = ctxdata->aTHX;
#endif

    PERL_UNUSED_VAR(jsmagic);
    SV* cb_sv = ((SV**) func_data)[0];

    SV* args[argc + 1];
    args[argc] = NULL;

    SV* error_sv = NULL;

    for (int a=0; a<argc; a++) {
        args[a] = _JSValue_to_SV(aTHX_ ctx, argv[a], &error_sv);

        if (error_sv) {
            while (--a >= 0) {
                SvREFCNT_dec(args[a]);
            }

            break;
        }
    }

    if (!error_sv) {
        SV* from_perl = exs_call_sv_scalar_trapped(cb_sv, args, &error_sv);

        if (from_perl) {
            JSValue to_js = _sv_to_jsvalue(aTHX_ ctx, from_perl, &error_sv);

            sv_2mortal(from_perl);

            if (!error_sv) return to_js;
        }
    }

    JSValue jserr = _sv_error_to_jsvalue(aTHX_ ctx, error_sv);

    return JS_Throw(ctx, jserr);
}

static JSValue _sviv_to_js(pTHX_ JSContext* ctx, SV* value) {
    if (sizeof(IV) == sizeof(int64_t)) {
        return JS_NewInt64(ctx, (int64_t) SvIV(value));
    }

    return JS_NewInt32(ctx, (int32_t) SvIV(value));
}

static JSValue _sv_to_jsvalue(pTHX_ JSContext* ctx, SV* value, SV** error_svp) {
    SvGETMAGIC(value);

    switch ( exs_sv_type(value) ) {
        case EXS_SVTYPE_UNDEF:
            return JS_NULL;

        case EXS_SVTYPE_BOOLEAN:
            return JS_NewBool(ctx, SvTRUE(value));

        case EXS_SVTYPE_STRING: STMT_START {
            STRLEN len;
            const char* str = SvPVutf8(value, len);

            return JS_NewStringLen(ctx, str, len);
        } STMT_END;

        case EXS_SVTYPE_UV: STMT_START {
            UV val_uv = SvUV(value);

            if (sizeof(UV) == sizeof(uint64_t)) {
                if (val_uv > IV_MAX) {
                    return JS_NewFloat64(ctx, val_uv);
                }
                else {
                    return JS_NewInt64(ctx, (int64_t) val_uv);
                }
            }
            else {
                return JS_NewUint32(ctx, (uint32_t) val_uv);
            }
        } STMT_END;

        case EXS_SVTYPE_IV: STMT_START {
            return _sviv_to_js(aTHX_ ctx, value);
        } STMT_END;

        case EXS_SVTYPE_NV: STMT_START {
            return JS_NewFloat64(ctx, (double) SvNV(value));
        } STMT_END;

        case EXS_SVTYPE_REFERENCE:
            if (sv_isobject(value)) {
                if (sv_derived_from(value, PERL_BOOLEAN_CLASS)) {
                    return JS_NewBool(ctx, SvTRUE(SvRV(value)));
                }
                else if (sv_derived_from(value, PQJS_JSOBJECT_CLASS)) {
                    perl_qjs_jsobj_s* pqjs = exs_structref_ptr(value);

                    if (LIKELY(pqjs->ctx == ctx)) {
                        return JS_DupValue(ctx, pqjs->jsobj);
                    }

                    *error_svp = newSVpvf("%s for QuickJS %p given to QuickJS %p!", sv_reftype(SvRV(value), 1), pqjs->ctx, ctx);
                    return JS_NULL;
                }

                break;
            }

            switch (SvTYPE(SvRV(value))) {
                case SVt_PVCV:
                    _ctx_add_sv(aTHX_ ctx, value);

                    /* A hack to store our callback via the func_data pointer: */
                    JSValue dummy = JS_MKPTR(JS_TAG_INT, value);

                    return JS_NewCFunctionData(
                        ctx,
                        __do_perl_callback,
                        0, 0,
                        1, &dummy
                    );

                case SVt_PVAV: STMT_START {
                    AV* av = (AV*) SvRV(value);
                    JSValue jsarray = JS_NewArray(ctx);
                    JS_SetPropertyStr(ctx, jsarray, "length", JS_NewUint32(ctx, 1 + av_len(av)));

                    for (int32_t i=0; i <= av_len(av); i++) {
                        SV** svp = av_fetch(av, i, 0);
                        assert(svp);
                        assert(*svp);

                        JSValue jsval = _sv_to_jsvalue(aTHX_ ctx, *svp, error_svp);

                        if (*error_svp) {
                            JS_FreeValue(ctx, jsarray);
                            return _sv_error_to_jsvalue(aTHX_ ctx, *error_svp);
                        }

                        JS_SetPropertyUint32(ctx, jsarray, i, jsval);
                    }

                    return jsarray;
                } STMT_END;

                case SVt_PVHV: STMT_START {
                    HV* hv = (HV*) SvRV(value);
                    JSValue jsobj = JS_NewObject(ctx);

                    hv_iterinit(hv);

                    HE* hvent;
                    while ( (hvent = hv_iternext(hv)) ) {
                        SV* key_sv = hv_iterkeysv(hvent);
                        SV* val_sv = hv_iterval(hv, hvent);

                        STRLEN keylen;
                        const char* key = SvPVutf8(key_sv, keylen);

                        JSValue jsval = _sv_to_jsvalue(aTHX_ ctx, val_sv, error_svp);
                        if (*error_svp) {
                            JS_FreeValue(ctx, jsobj);
                            return _sv_error_to_jsvalue(aTHX_ ctx, *error_svp);
                        }

                        JSAtom prop = JS_NewAtomLen(ctx, key, keylen);

                        /* NB: ctx takes over jsval. */
                        JS_DefinePropertyValue(ctx, jsobj, prop, jsval, JS_PROP_WRITABLE);

                        JS_FreeAtom(ctx, prop);
                    }

                    return jsobj;
                } STMT_END;

                default:
                    break;
            }

        default:
            break;
    }

    *error_svp = newSVpvf("Cannot convert %" SVf " to JavaScript!", value);

    return JS_NULL;
}

static JSContext* _create_new_jsctx( pTHX_ JSRuntime *rt ) {
    JSContext *ctx = JS_NewContext(rt);

    ctx_opaque_s* ctxdata;
    Newxz(ctxdata, 1, ctx_opaque_s);
    JS_SetContextOpaque(ctx, ctxdata);

    JSValue global = JS_GetGlobalObject(ctx);

    *ctxdata = (ctx_opaque_s) {
        .refcount = 1,
        .regexp_jsvalue = JS_GetPropertyStr(ctx, global, "RegExp"),
        .date_jsvalue = JS_GetPropertyStr(ctx, global, "Date"),
        .promise_jsvalue = JS_GetPropertyStr(ctx, global, "Promise"),
#ifdef MULTIPLICITY
        .aTHX = aTHX,
#endif
    };

    JS_FreeValue(ctx, global);

    return ctx;
}

static SV* _get_exception_from_jsvalue(pTHX_ JSContext* ctx, JSValue jsret) {
    SV* err;

    JSValue jserr = JS_GetException(ctx);
    //err = _JSValue_to_SV(aTHX_ ctx, jserr);

    /* Ideal here is to capture all aspects of the error object,
        including its `name` and members. But for now just give
        a string.

        JSValue jslen = JS_GetPropertyStr(ctx, jserr, "name");
        STRLEN namelen;
        const char* namestr = JS_ToCStringLen(ctx, &namelen, jslen);
    */

    STRLEN strlen;
    const char* str = JS_ToCStringLen(ctx, &strlen, jserr);

    err = newSVpvn_flags(str, strlen, SVf_UTF8);

    JS_FreeCString(ctx, str);
    JS_FreeValue(ctx, jserr);

    return err;
}

static inline SV* _return_jsvalue_or_croak(pTHX_ JSContext* ctx, JSValue jsret) {
    SV* err;
    SV* RETVAL;

    if (JS_IsException(jsret)) {
        err = _get_exception_from_jsvalue(aTHX_ ctx, jsret);
        RETVAL = NULL;  // silence uninitialized warning
    }
    else {
        err = NULL;
        RETVAL = _JSValue_to_SV(aTHX_ ctx, jsret, &err);
    }

    JS_FreeValue(ctx, jsret);

    if (err) croak_sv(err);

    return RETVAL;
}

static void _free_jsctx(pTHX_ JSContext* ctx) {
    ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);

    if (--ctxdata->refcount == 0) {
        JS_FreeValue(ctx, ctxdata->regexp_jsvalue);
        JS_FreeValue(ctx, ctxdata->date_jsvalue);
        JS_FreeValue(ctx, ctxdata->promise_jsvalue);

        JSRuntime *rt = JS_GetRuntime(ctx);

        for (U32 i=0; i<ctxdata->svs_count; i++) {
            SvREFCNT_dec(ctxdata->svs[i]);
        }

        if (ctxdata->ran_js_std_init_handlers) {
            js_std_free_handlers(rt);
        }

        Safefree(ctxdata);

        JS_FreeContext(ctx);

        JS_FreeRuntime(rt);
    }
}

static JSModuleDef *pqjs_module_loader(JSContext *ctx,
                              const char *module_name, void *opaque) {
    char** module_base_path_p = (char**) opaque;

    char* module_base_path = *module_base_path_p;

    JSModuleDef *moduledef;

    if (module_base_path) {
        size_t base_path_len = strlen(module_base_path);
        size_t module_name_len = strlen(module_name);

        char real_path[1 + base_path_len + module_name_len];

        memcpy(real_path, module_base_path, base_path_len);
        memcpy(real_path + base_path_len, module_name, module_name_len);
        real_path[base_path_len + module_name_len] = 0;

        moduledef = js_module_loader(ctx, real_path, NULL);
    }
    else {
        moduledef = js_module_loader(ctx, module_name, NULL);
    }

    return moduledef;
}

/* These must correlate to the ALIAS values below. */
static const char* _REGEXP_ACCESSORS[] = {
    "flags",
    "dotAll",
    "global",
    "hasIndices",
    "ignoreCase",
    "multiline",
    "source",
    "sticky",
    "unicode",
    "lastIndex",
};

/* These must correlate to the ALIAS values below. */
static const char* _FUNCTION_ACCESSORS[] = {
    "length",
    "name",
};

#define FUNC_CALL_INITIAL_ARGS 2

// returns the SV to croak.
static SV* _svs_to_jsvars(pTHX_ JSContext* jsctx, int32_t params_count, SV** svs, JSValue* jsvars) {
    SV* error = NULL;

    for (int32_t i=0; i<params_count; i++) {
        SV* cur_sv = svs[i];

        JSValue jsval = _sv_to_jsvalue(aTHX_ jsctx, cur_sv, &error);

        if (error) {
            while (--i >= 0) {
                JS_FreeValue(jsctx, jsvars[i]);
            }

            break;
        }

        jsvars[i] = jsval;
    }

    return error;
}

static void _import_module_to_global(pTHX_ JSContext* jsctx, const char* modname) {
    const char* jstemplate = "import * as theModule from '%s';\n"
        "globalThis.%s = theModule;\n";

    char js[255] = { 0 };
    snprintf(js, 255, jstemplate, modname, modname);

    JSValue val = JS_Eval(jsctx, js, strlen(js), "<input>", JS_EVAL_TYPE_MODULE);
    if (JS_IsException(val)) {
        SV* errsv = _get_exception_from_jsvalue(aTHX_ jsctx, val);
        if (errsv) {
            croak_sv(errsv);
        }

        croak("Got empty exception??");
    }

    JS_FreeValue(jsctx, val);
}

/* ---------------------------------------------------------------------- */

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS

PROTOTYPES: DISABLE

SV*
_new (SV* classname_sv)
    CODE:
        JSRuntime *rt = JS_NewRuntime();
        JS_SetHostPromiseRejectionTracker(rt, js_std_promise_rejection_tracker, NULL);
        JS_SetModuleLoaderFunc(rt, NULL, js_module_loader, NULL);

        JSContext *ctx = _create_new_jsctx(aTHX_ rt);

        RETVAL = exs_new_structref(perl_qjs_s, SvPVbyte_nolen(classname_sv));
        perl_qjs_s* pqjs = exs_structref_ptr(RETVAL);

        *pqjs = (perl_qjs_s) {
            .ctx = ctx,
            .pid = getpid(),
        };

        JS_SetModuleLoaderFunc(
            rt,
            NULL,
            pqjs_module_loader,
            &pqjs->module_base_path
        );

        JS_SetRuntimeInfo(rt, PERL_NS_ROOT);

    OUTPUT:
        RETVAL

void
DESTROY (SV* self_sv)
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        if (PL_dirty && pqjs->pid == getpid()) {
            warn("DESTROYing %" SVf " at global destruction; memory leak likely!\n", self_sv);
        }

        if (pqjs->module_base_path) Safefree(pqjs->module_base_path);

        _free_jsctx(aTHX_ pqjs->ctx);

SV*
_configure (SV* self_sv, SV* max_stack_size_sv, SV* memory_limit_sv, SV* gc_threshold_sv)
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        JSRuntime *rt = JS_GetRuntime(pqjs->ctx);

        if (SvOK(max_stack_size_sv)) {
            JS_SetMaxStackSize(rt, exs_SvUV(max_stack_size_sv));
        }

        if (SvOK(memory_limit_sv)) {
            JS_SetMemoryLimit(rt, exs_SvUV(memory_limit_sv));
        }

        if (SvOK(gc_threshold_sv)) {
            JS_SetGCThreshold(rt, exs_SvUV(gc_threshold_sv));
        }

        RETVAL = SvREFCNT_inc(self_sv);

    OUTPUT:
        RETVAL

SV*
std (SV* self_sv)
    ALIAS:
        os = 1
        helpers = 2
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        switch (ix) {
            case 0:
                if (!pqjs->added_std) {
                    js_init_module_std(pqjs->ctx, "std");
                    _import_module_to_global(aTHX_ pqjs->ctx, "std");
                    pqjs->added_std = true;
                }

                break;
            case 1:
                if (!pqjs->added_os) {
                    js_init_module_os(pqjs->ctx, "os");
                    pqjs->added_os = true;

                    ctx_opaque_s* ctxdata = JS_GetContextOpaque(pqjs->ctx);

                    if (!ctxdata->ran_js_std_init_handlers) {
                        JSRuntime *rt = JS_GetRuntime(pqjs->ctx);
                        js_std_init_handlers(rt);

                        ctxdata->ran_js_std_init_handlers = true;
                    }

                    _import_module_to_global(aTHX_ pqjs->ctx, "os");
                }

                break;
            case 2:
                if (!pqjs->added_helpers) {
                    js_std_add_helpers(pqjs->ctx, 0, NULL);
                    pqjs->added_helpers = true;
                }

                break;

            default:
                croak("%s: Bad XS alias: %d\n", __func__, (int) ix);
        }

        RETVAL = SvREFCNT_inc(self_sv);

    OUTPUT:
        RETVAL

SV*
unset_module_base (SV* self_sv)
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        if (pqjs->module_base_path) {
            Safefree(pqjs->module_base_path);
            pqjs->module_base_path = NULL;
        }

        RETVAL = SvREFCNT_inc(self_sv);
    OUTPUT:
        RETVAL

SV*
set_module_base (SV* self_sv, SV* path_sv)
    CODE:
        if (!SvOK(path_sv)) croak("Give a path! (Did you want unset_module_base?)");

        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        const char* path = exs_SvPVbyte_nolen(path_sv);

        size_t path_len = strlen(path);

        if (pqjs->module_base_path) {
            Renew(pqjs->module_base_path, 2 + path_len, char);
        }
        else {
            Newx(pqjs->module_base_path, 2 + path_len, char);
        }

        Copy(path, pqjs->module_base_path, 2 + path_len, char);

        /** If the given path is “/foo/bar”, we store “/foo/bar/”.
            This means if “/foo/bar/” is given we store “/foo/bar//”,
            which is ugly but should work on all supported platforms.
        */
        pqjs->module_base_path[path_len] = PATH_SEPARATOR;
        pqjs->module_base_path[1 + path_len] = 0;

        RETVAL = SvREFCNT_inc(self_sv);
    OUTPUT:
        RETVAL

SV*
set_globals (SV* self_sv, ...)
    CODE:
        if (items < 2) croak("Need at least 1 key/value pair.");

        if (!(items % 2)) croak("Need an even list of key/value pairs.");

        I32 valscount = (items - 1) >> 1;

        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        SV* jsname_sv, *value_sv;

        SV* error = NULL;

        JSAtom jsnames[valscount];
        JSValue jsvals[valscount];

        for (int i=0; i < valscount; i++) {
            jsname_sv = ST( 1 + (i << 1) );
            value_sv = ST( 2 + (i << 1) );

            STRLEN jsnamelen;
            const char* jsname_str = SvPVutf8(jsname_sv, jsnamelen);

            JSValue jsval = _sv_to_jsvalue(aTHX_ pqjs->ctx, value_sv, &error);

            if (error) {
                while (i-- > 0) {
                    JS_FreeAtom(pqjs->ctx, jsnames[i]);
                    JS_FreeValue(pqjs->ctx, jsvals[i]);
                }

                croak_sv(error);
            }

            jsnames[i] = JS_NewAtomLen(pqjs->ctx, jsname_str, jsnamelen);
            jsvals[i] = jsval;
        }

        JSValue jsglobal = JS_GetGlobalObject(pqjs->ctx);

        for (int i=0; i < valscount; i++) {
            /* NB: ctx takes over jsval. */
            JS_DefinePropertyValue(pqjs->ctx, jsglobal, jsnames[i], jsvals[i], JS_PROP_WRITABLE);
            JS_FreeAtom(pqjs->ctx, jsnames[i]);
        }

        JS_FreeValue(pqjs->ctx, jsglobal);

        RETVAL = SvREFCNT_inc(self_sv);

    OUTPUT:
        RETVAL

SV*
eval (SV* self_sv, SV* js_code_sv)
    ALIAS:
        eval_module = 1
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);
        JSContext *ctx = pqjs->ctx;

        STRLEN js_code_len;
        const char* js_code = SvPVutf8(js_code_sv, js_code_len);

        int eval_flags = ix ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL;
        eval_flags |= JS_EVAL_FLAG_STRICT;

        JSValue jsret = JS_Eval(ctx, js_code, js_code_len, "", eval_flags);

        // In eval_module()’s case we want to croak if there was
        // an exception. If not we’ll just discard the return value
        RETVAL = _return_jsvalue_or_croak(aTHX_ ctx, jsret);

    OUTPUT:
        RETVAL

SV*
await (SV* self_sv)
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);
        JSContext *ctx = pqjs->ctx;

        js_std_loop(ctx);

        RETVAL = SvREFCNT_inc(self_sv);

    OUTPUT:
        RETVAL

# ----------------------------------------------------------------------

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS::Date

SV*
setTime (SV* self_sv, SV* num_sv)
    ALIAS:
        setMilliseconds = 1
        setUTCMilliseconds = 2
        setSeconds = 3
        setUTCSeconds = 4
        setMinutes = 5
        setUTCMinutes = 6
        setHours = 7
        setUTCHours = 8
        setDate = 9
        setUTCDate = 10
        setMonth = 11
        setUTCMonth = 12
        setFullYear = 13
        setUTCFullYear = 14

    CODE:
        const char* setter_name = DATE_SETTER_FROM_IX[ix];

        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);
        JSContext *ctx = pqjs->ctx;

        JSAtom prop = JS_NewAtom(ctx, setter_name);

        JSValue arg;
        switch (exs_sv_type(num_sv)) {

            // In 32-bit perls setTime() values often overflow IV_MAX.
            case EXS_SVTYPE_NV:
                NV nvval = SvNV(num_sv);
                if (nvval > IV_MAX || nvval < IV_MIN) {
                    arg = JS_NewFloat64(ctx, (double) nvval);
                    break;
                }

                // fallthrough

            default:
                    arg = _sviv_to_js(aTHX_ ctx, num_sv);
        }

        JSValue jsret = JS_Invoke(
            ctx,
            pqjs->jsobj,
            prop,
            1,
            &arg
        );

        JS_FreeAtom(ctx, prop);
        JS_FreeValue(ctx, arg);

        RETVAL = _return_jsvalue_or_croak(aTHX_ pqjs->ctx, jsret);

    OUTPUT:
        RETVAL

SV*
toString (SV* self_sv, ...)
    ALIAS:
        toUTCString = 1
        toGMTString = 2
        toISOString = 3
        toDateString = 4
        toTimeString = 5
        toLocaleString = 6
        toLocaleDateString = 7
        toLocaleTimeString = 8
        getTimezoneOffset = 9
        getTime = 10
        getFullYear = 11
        getUTCFullYear = 12
        getMonth = 13
        getUTCMonth = 14
        getDate = 15
        getUTCDate = 16
        getHours = 17
        getUTCHours = 18
        getMinutes = 19
        getUTCMinutes = 20
        getSeconds = 21
        getUTCSeconds = 22
        getMilliseconds = 23
        getUTCMilliseconds = 24
        getDay = 25
        getUTCDay = 26
        toJSON = 27
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);
        JSContext *ctx = pqjs->ctx;

        JSAtom prop = JS_NewAtom(ctx, DATE_GETTER_FROM_IX[ix]);

        JSValue jsret;

        if (items > 1) {
            int params_count = items - 1;

            JSValue jsargs[params_count];

            SV* error = _svs_to_jsvars(aTHX_ ctx, params_count, &ST(1), jsargs);
            if (error) {
                JS_FreeAtom(pqjs->ctx, prop);
                croak_sv(error);
            }

            jsret = JS_Invoke(
                ctx,
                pqjs->jsobj,
                prop,
                params_count,
                jsargs
            );

            for (uint32_t i=0; i<params_count; i++) {
                JS_FreeValue(ctx, jsargs[i]);
            }
        }
        else {
            jsret = JS_Invoke(
                ctx,
                pqjs->jsobj,
                prop,
                0,
                NULL
            );
        }

        JS_FreeAtom(ctx, prop);

        RETVAL = _return_jsvalue_or_croak(aTHX_ pqjs->ctx, jsret);

    OUTPUT:
        RETVAL

# ----------------------------------------------------------------------

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS::RegExp

SV*
exec (SV* self_sv, SV* specimen_sv)
    ALIAS:
        test = 1
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);
        JSContext *ctx = pqjs->ctx;

        STRLEN specimen_len;
        const char* specimen = SvPVutf8(specimen_sv, specimen_len);

        /* TODO: optimize? */
        JSAtom prop = JS_NewAtom(ctx, ix ? "test" : "exec");

        JSValue specimen_js = JS_NewStringLen(ctx, specimen, specimen_len);

        JSValue jsret = JS_Invoke(
            ctx,
            pqjs->jsobj,
            prop,
            1,
            &specimen_js
        );

        JS_FreeValue(ctx, specimen_js);
        JS_FreeAtom(ctx, prop);

        RETVAL = _return_jsvalue_or_croak(aTHX_ pqjs->ctx, jsret);

    OUTPUT:
        RETVAL

SV*
flags( SV* self_sv)
    ALIAS:
        dotAll = 1
        global = 2
        hasIndices = 3
        ignoreCase = 4
        multiline = 5
        source = 6
        sticky = 7
        unicode = 8
        lastIndex = 9
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);

        JSValue myret = JS_GetPropertyStr(pqjs->ctx, pqjs->jsobj, _REGEXP_ACCESSORS[ix]);

        SV* err = NULL;

        RETVAL = _JSValue_to_SV(aTHX_ pqjs->ctx, myret, &err);

        JS_FreeValue(pqjs->ctx, myret);

        if (err) croak_sv(err);

    OUTPUT:
        RETVAL

# ----------------------------------------------------------------------

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS::JSObject

void
DESTROY( SV* self_sv )
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);

        if (PL_dirty && pqjs->pid == getpid()) {
            warn("DESTROYing %" SVf " at global destruction; memory leak likely!\n", self_sv);
        }

        JS_FreeValue(pqjs->ctx, pqjs->jsobj);

        _free_jsctx(aTHX_ pqjs->ctx);

# ----------------------------------------------------------------------

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS::Function

SV*
_give_self( SV* self_sv, ... )
    CODE:
        RETVAL = SvREFCNT_inc(self_sv);
    OUTPUT:
        RETVAL

SV*
length( SV* self_sv)
    ALIAS:
        name = 1
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);

        JSValue myret = JS_GetPropertyStr(pqjs->ctx, pqjs->jsobj, _FUNCTION_ACCESSORS[ix]);

        SV* err = NULL;

        RETVAL = _JSValue_to_SV(aTHX_ pqjs->ctx, myret, &err);

        JS_FreeValue(pqjs->ctx, myret);

        if (err) croak_sv(err);

    OUTPUT:
        RETVAL

SV*
call( SV* self_sv, SV* this_sv=&PL_sv_undef, ... )
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);

        U32 params_count = items - FUNC_CALL_INITIAL_ARGS;

        SV* error = NULL;

        JSValue thisjs = _sv_to_jsvalue(aTHX_ pqjs->ctx, this_sv, &error);
        if (error) croak_sv(error);

        JSValue jsvars[params_count];

        error = _svs_to_jsvars( aTHX_ pqjs->ctx, params_count, &ST(FUNC_CALL_INITIAL_ARGS), jsvars );
        if (error) {
            JS_FreeValue(pqjs->ctx, thisjs);
            croak_sv(error);
        }

        JSValue jsret = JS_Call(pqjs->ctx, pqjs->jsobj, thisjs, params_count, jsvars);

        JS_FreeValue(pqjs->ctx, thisjs);

        for (uint32_t i=0; i<params_count; i++) {
            JS_FreeValue(pqjs->ctx, jsvars[i]);
        }

        RETVAL = _return_jsvalue_or_croak(aTHX_ pqjs->ctx, jsret);

    OUTPUT:
        RETVAL

# ----------------------------------------------------------------------

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS::Promise

SV*
then( SV* self_sv, SV* on_success=&PL_sv_undef, SV* on_failure=&PL_sv_undef )
    CODE:
        PERL_UNUSED_ARG(on_success);
        PERL_UNUSED_ARG(on_failure);

        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);

        SV* error = NULL;

        JSValue jsvars[2];
        int callbacks_count = sizeof(jsvars) / sizeof(jsvars[0]);

        error = _svs_to_jsvars( aTHX_
            pqjs->ctx,
            callbacks_count,
            &ST(1),
            jsvars
        );
        if (error) {
            croak_sv(error);
        }

        JSAtom method_name = JS_NewAtom(pqjs->ctx, "then");

        JSValue jsret = JS_Invoke(
            pqjs->ctx,
            pqjs->jsobj,
            method_name,
            callbacks_count,
            jsvars
        );

        JS_FreeAtom(pqjs->ctx, method_name);

        for (uint32_t i=0; i<callbacks_count; i++) {
            JS_FreeValue(pqjs->ctx, jsvars[i]);
        }

        RETVAL = _return_jsvalue_or_croak(aTHX_ pqjs->ctx, jsret);

    OUTPUT:
        RETVAL

SV*
catch( SV* self_sv, SV* callback=&PL_sv_undef)
    ALIAS:
        finally = 1
    CODE:
        perl_qjs_jsobj_s* pqjs = exs_structref_ptr(self_sv);

        SV* error = NULL;

        JSValue callbackjs = _sv_to_jsvalue(aTHX_ pqjs->ctx, callback, &error);
        if (error) croak_sv(error);

        JSAtom method_name = JS_NewAtom(pqjs->ctx, ix ? "finally" : "catch");

        JSValue jsret = JS_Invoke(
            pqjs->ctx,
            pqjs->jsobj,
            method_name,
            1,
            &callbackjs
        );

        JS_FreeAtom(pqjs->ctx, method_name);
        JS_FreeValue(pqjs->ctx, callbackjs);

        RETVAL = _return_jsvalue_or_croak(aTHX_ pqjs->ctx, jsret);

    OUTPUT:
        RETVAL
