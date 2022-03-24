#include "easyxs/easyxs.h"
#include "quickjs/quickjs.h"
#include "quickjs/quickjs-libc.h"

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

/* NO exceptions allowed here! */
static SV* _JSValue_to_SV (pTHX_ JSContext* ctx, JSValue jsval) {
    SV* RETVAL;

    if (JS_IsArray(ctx, jsval)) {
        RETVAL = _JSValue_array_to_SV(aTHX_ ctx, jsval);
    }
    else {
        switch (JS_VALUE_GET_TAG(jsval)) {
            case JS_TAG_EXCEPTION:
                croak("DEV ERROR: Exception must be unwrapped!");

            case JS_TAG_STRING:
                STMT_START {
                    STRLEN strlen;
                    const char* str = JS_ToCStringLen(ctx, &strlen, jsval);
                    RETVAL = newSVpvn_flags(str, strlen, SVf_UTF8);
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
                RETVAL = _JSValue_object_to_SV(aTHX_ ctx, jsval);
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
    }

    return RETVAL;
}

static inline void _add_niceties_to_ctx (JSContext *ctx) {
    js_std_add_helpers(ctx, 0, NULL);

    js_init_module_std(ctx, "std");
    js_init_module_os(ctx, "os");
}

static inline void _add_niceties_to_rt (JSRuntime *rt) {
    /* loader for ES6 modules */
    JS_SetModuleLoaderFunc(rt, NULL, js_module_loader, NULL);
}

/* ---------------------------------------------------------------------- */

MODULE = JavaScript::QuickJS        PACKAGE = JavaScript::QuickJS

SV*
run (SV* js_code_sv)
    CODE:
        JSRuntime *rt = JS_NewRuntime();
        _add_niceties_to_rt(rt);

        // Assuming this is off by default because this wasn’t how
        // JS engines originally worked?
        //JS_SetHostPromiseRejectionTracker(rt, js_std_promise_rejection_tracker, NULL);

        JSContext *ctx = JS_NewContext(rt);
        _add_niceties_to_ctx(ctx);

        STRLEN js_code_len;
        const char* js_code = SvPVutf8(js_code_sv, js_code_len);

        JSValue jsret = JS_Eval(ctx, js_code, js_code_len, "", JS_EVAL_TYPE_GLOBAL);

        SV* err;

        if (JS_IsException(jsret)) {
            JSValue jserr = JS_GetException(ctx);
            //err = _JSValue_to_SV(aTHX_ ctx, jserr);

            /* Ideal here is to capture all aspects of the error object,
               including its `name` and members. But for now just give
               a string.
            */

            STRLEN strlen;
            const char* str = JS_ToCStringLen(ctx, &strlen, jserr);
            err = newSVpvn_flags(str, strlen, SVf_UTF8);
            JS_FreeValue(ctx, jserr);
        }
        else {
            err = NULL;
            RETVAL = _JSValue_to_SV(aTHX_ ctx, jsret);
        }

        JS_FreeValue(ctx, jsret);
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);

        if (err) croak_sv(err);

    OUTPUT:
        RETVAL

PROTOTYPES: DISABLE
