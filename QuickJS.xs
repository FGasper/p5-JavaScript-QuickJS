#include "easyxs/easyxs.h"

#include "quickjs/quickjs.h"
#include "quickjs/quickjs-libc.h"

typedef struct {
    JSContext *ctx;
} perl_qjs_s;

typedef struct {
#ifdef MULTIPLICITY
    pTHX;
#endif
    SV** svs;
    U32 svs_count;
} ctx_opaque_s;

const char* __jstype_name_back[] = {
    [JS_TAG_BIG_DECIMAL - JS_TAG_FIRST] = "big decimal",
    [JS_TAG_BIG_INT - JS_TAG_FIRST] = "big int",
    [JS_TAG_BIG_FLOAT - JS_TAG_FIRST] = "big float",
    [JS_TAG_SYMBOL - JS_TAG_FIRST] = "symbol",
    [JS_TAG_MODULE - JS_TAG_FIRST] = "module",
    [JS_TAG_OBJECT - JS_TAG_FIRST] = "object",
    [JS_TAG_FLOAT64 - JS_TAG_FIRST] = "float64",

    /* Small hack to ensure we can always read: */
    [99] = NULL,
};

#define _jstype_name(typenum) __jstype_name_back[ JS_TAG_FIRST + typenum ]

static SV* _JSValue_to_SV (pTHX_ JSContext* ctx, JSValue jsval);

static inline SV* _JSValue_object_to_SV (pTHX_ JSContext* ctx, JSValue jsval) {
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

        hv_store(hv, keystr, -strlen, _JSValue_to_SV(aTHX_ ctx, value), 0);

        JS_FreeCString(ctx, keystr);
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, value);
        JS_FreeAtom(ctx, tab_atom[i].atom);
    }

    js_free(ctx, tab_atom);

    return newRV_noinc((SV*) hv);
}

static inline SV* _JSValue_array_to_SV (pTHX_ JSContext* ctx, JSValue jsval) {
    JSValue jslen = JS_GetPropertyStr(ctx, jsval, "length");
    uint32_t len;
    JS_ToUint32(ctx, &len, jslen);
    JS_FreeValue(ctx, jslen);

    AV* av = newAV();
    av_fill( av, len - 1 );
    for (uint32_t i=0; i<len; i++) {
        JSValue jsitem = JS_GetPropertyUint32(ctx, jsval, i);
        av_store( av, i, _JSValue_to_SV(aTHX_ ctx, jsitem) );
        JS_FreeValue(ctx, jsitem);
    }

    return newRV_noinc((SV*) av);
}

/* NO JS exceptions allowed here! */
static SV* _JSValue_to_SV (pTHX_ JSContext* ctx, JSValue jsval) {
    SV* RETVAL;

    switch (JS_VALUE_GET_TAG(jsval)) {
        case JS_TAG_EXCEPTION:
            croak("DEV ERROR: Exception must be unwrapped!");

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
                croak("Cannot convert JS function to Perl!");
            }
            else if (JS_IsArray(ctx, jsval)) {
                RETVAL = _JSValue_array_to_SV(aTHX_ ctx, jsval);
            }
            else {
                RETVAL = _JSValue_object_to_SV(aTHX_ ctx, jsval);
            }

            break;

        default:
            STMT_START {
                const char* typename = _jstype_name(JS_VALUE_GET_TAG(jsval));

                if (typename) {
                    croak("Cannot convert JS %s (QuickJS tag %d) to Perl!", typename, JS_VALUE_GET_TAG(jsval));
                }
                else {
                    croak("Cannot convert (unexpected) JS tag value %d to Perl!", JS_VALUE_GET_TAG(jsval));
                }
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

static JSValue _sv_to_jsvalue(pTHX_ JSContext* ctx, SV* value);

static JSValue __do_perl_callback(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int jsmagic, JSValue *func_data) {
    ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);
#ifdef MULTIPLICITY
    pTHX = ctxdata->aTHX;
#endif

    PERL_UNUSED_VAR(jsmagic);
    SV* cb_sv = ((SV**) func_data)[0];

    SV* args[argc + 1];
    args[argc] = NULL;

    // TODO: Avoid exceptions here:
    for (int a=0; a<argc; a++) {
        args[a] = _JSValue_to_SV(aTHX_ ctx, argv[a]);
    }

    // TODO: Trap exceptions
    SV* retval = exs_call_sv_scalar(cb_sv, args);

    return _sv_to_jsvalue(aTHX_ ctx, retval);
}

static JSValue _sv_to_jsvalue(pTHX_ JSContext* ctx, SV* value) {
    if (!SvOK(value)) {
        return JS_NULL;
    }

    if (SvROK(value)) {
        switch (SvTYPE(SvRV(value))) {
            case SVt_PVCV:
                _ctx_add_sv(aTHX_ ctx, value);
                return JS_NewCFunctionData(
                    ctx,
                    __do_perl_callback,
                    0, 0,
                    1, &(JS_MKPTR(JS_TAG_INT, value))
                );

            default:
                /* We’ll croak below. */
                break;
        }
    }
    else {
        if (SvNOK(value)) {
            return JS_NewFloat64(ctx, (double) SvNV(value));
        }

        if (SvUOK(value)) {
            if (sizeof(IV) == sizeof(uint64_t)) {
                return JS_NewInt64(ctx, (uint64_t) SvIV(value));
            }

            return JS_NewInt32(ctx, (uint32_t) SvIV(value));
        }
        if (SvIOK(value)) {
            if (sizeof(IV) == sizeof(int64_t)) {
                return JS_NewInt64(ctx, (int64_t) SvIV(value));
            }

            return JS_NewInt32(ctx, (int32_t) SvIV(value));
        }

        if (SvPOK(value)) {
            STRLEN len;
            const char* str = SvPVutf8(value, len);

            return JS_NewStringLen(ctx, str, len);
        }
    }

    croak("Cannot convert %" SVf " to JavaScript!", value);
}

JSContext* _create_new_jsctx( pTHX_ JSRuntime *rt ) {
    JSContext *ctx = JS_NewContext(rt);

    ctx_opaque_s* ctxdata;
    Newxz(ctxdata, 1, ctx_opaque_s);
    JS_SetContextOpaque(ctx, ctxdata);

#ifdef MULTIPLICITY
    ctxdata->aTHX = aTHX;
#endif

    return ctx;
}

/* ---------------------------------------------------------------------- */

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS

PROTOTYPES: DISABLE

SV*
new (SV* classname_sv)
    CODE:
        JSRuntime *rt = JS_NewRuntime();
        JS_SetHostPromiseRejectionTracker(rt, js_std_promise_rejection_tracker, NULL);
        JS_SetModuleLoaderFunc(rt, NULL, js_module_loader, NULL);

        JSContext *ctx = _create_new_jsctx(aTHX_ rt);

        RETVAL = exs_new_structref(perl_qjs_s, SvPVbyte_nolen(classname_sv));
        perl_qjs_s* pqjs = exs_structref_ptr(RETVAL);

        pqjs->ctx = ctx;

    OUTPUT:
        RETVAL

void
DESTROY (SV* self_sv)
    CODE:
        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);
        JSContext *ctx = pqjs->ctx;
        JSRuntime *rt = JS_GetRuntime(ctx);

        ctx_opaque_s* ctxdata = JS_GetContextOpaque(ctx);
        for (U32 i=0; i<ctxdata->svs_count; i++) {
            SvREFCNT_dec(ctxdata->svs[i]);
        }

        Safefree(ctxdata);

        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);

SV*
std (SV* self_sv)
    ALIAS:
        os = 1
        helpers = 2
    CODE:
        RETVAL = SvREFCNT_inc(self_sv);

        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        switch (ix) {
            case 0:
                js_init_module_std(pqjs->ctx, "std");
                break;
            case 1:
                js_init_module_os(pqjs->ctx, "os");
                break;
            case 2:
                js_std_add_helpers(pqjs->ctx, 0, NULL);

            default:
                assert(0);
        }

    OUTPUT:
        RETVAL

SV*
set_global (SV* self_sv, SV* jsname_sv, SV* value_sv)
    CODE:
        RETVAL = SvREFCNT_inc(self_sv);

        perl_qjs_s* pqjs = exs_structref_ptr(self_sv);

        JSValue jsval = _sv_to_jsvalue(aTHX_ pqjs->ctx, value_sv);

        JSValue jsglobal = JS_GetGlobalObject(pqjs->ctx);

        STRLEN jsnamelen;
        const char* jsname_str = SvPVutf8(jsname_sv, jsnamelen);

        JSAtom prop = JS_NewAtomLen(pqjs->ctx, jsname_str, jsnamelen);

        /* NB: ctx takes over jsval. */
        JS_DefinePropertyValue(pqjs->ctx, jsglobal, prop, jsval, 0);

        JS_FreeAtom(pqjs->ctx, prop);
        JS_FreeValue(pqjs->ctx, jsglobal);

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
        JSValue jsret = JS_Eval(ctx, js_code, js_code_len, "", eval_flags);

        SV* err;

        if (JS_IsException(jsret)) {
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
        }
        else {
            err = NULL;
            RETVAL = _JSValue_to_SV(aTHX_ ctx, jsret);
        }

        JS_FreeValue(ctx, jsret);

        if (err) croak_sv(err);

    OUTPUT:
        RETVAL
