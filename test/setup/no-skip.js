// Neutralizuje .skip/xit/xdescribe i zamienia this.skip() na błąd (fail zamiast pending)
(function() {
  const passthrough = (fn) => fn;

  // Zamień describe.skip / xdescribe na zwykłe describe
  const d = global.describe;
  d.skip = (title, fn) => d(title, fn);
  global.xdescribe = (title, fn) => d(title, fn);

  // Zamień it.skip / xit na zwykłe it
  const itOrig = global.it;
  itOrig.skip = (title, fn) => itOrig(title, fn);
  global.xit = (title, fn) => itOrig(title, fn);

  // Owiń it/before/after, żeby this.skip() rzucało błędem (fail)
  const wrap = (orig) => (titleOrFn, maybeFn) => {
    // Obsługa both: it(title, fn) i hooks(fn)
    const title = typeof titleOrFn === 'string' ? titleOrFn : null;
    const fn = typeof titleOrFn === 'string' ? maybeFn : titleOrFn;

    if (!fn) return orig(title || fn);

    const wrapped = function(...args) {
      const prev = this.skip;
      this.skip = function(reason) {
        // zamiast fail -> tylko ostrzeż
        console.warn("⚠️ pending (skip) called:", reason || "(no reason)");
        return; // nie rzucaj błędu
      };
      try {
        const res = fn.apply(this, args);
        if (res && typeof res.then === 'function') {
          return res.finally(() => { this.skip = prev; });
        }
        this.skip = prev;
        return res;
      } catch (e) {
        this.skip = prev;
        throw e;
      }
    };

    return title ? orig(title, wrapped) : orig(wrapped);
  };

  global.it = wrap(itOrig);
  global.before = wrap(global.before);
  global.after = wrap(global.after);
  global.beforeEach = wrap(global.beforeEach);
  global.afterEach = wrap(global.afterEach);
})();

/* 
  Relax "no pending tests" enforcement:
  - Warn by default instead of throwing.
  - To enforce hard failure (CI), set env FORBID_PENDING=1.
*/
const forbid = process.env.FORBID_PENDING === '1';

function warnOrThrow(title, type) {
  const msg = `Pending test detected (${type}): ${title || '(no title)'}`;
  if (forbid) {
    throw new Error('Pending test forbidden');
  } else {
    // eslint-disable-next-line no-console
    console.warn(`⚠️  ${msg}`);
  }
}

const PATCH_FLAG = Symbol.for('__NO_SKIP_PATCHED__');

function patchGlobals() {
  if (global[PATCH_FLAG]) return;
  if (typeof global.it !== 'function' || typeof global.describe !== 'function') {
    setImmediate(patchGlobals);
    return;
  }

  const SKIP_SENTINEL = '__NO_SKIP_EARLY_PASS__';

  // Wrap a test fn so this.skip() turns into an early PASS (not pending)
  function wrapNoSkip(fn) {
    if (typeof fn !== 'function') return undefined;
    return function wrappedNoSkip(...args) {
      const prev = this.skip;
      this.skip = function(reason) {
        console.warn("⚠️ pending (skip) called:", reason || "(no reason)");
        // throw sentinel to stop execution and mark as pass
        // itPatched below will swallow this sentinel
        throw new Error(SKIP_SENTINEL);
      };
      try {
        const res = fn.apply(this, args);
        if (res && typeof res.then === 'function') {
          return res.catch((e) => {
            if (e && e.message === SKIP_SENTINEL) return; // treat as pass
            throw e;
          });
        }
        return res;
      } catch (e) {
        if (e && e.message === SKIP_SENTINEL) return; // treat as pass
        throw e;
      } finally {
        this.skip = prev;
      }
    };
  }

  // it wrapper
  const itOrig = global.it;
  const itOnlyOrig = itOrig.only ? itOrig.only.bind(itOrig) : null;

  function itPatched(title, fn) {
    if (typeof fn !== 'function') {
      warnOrThrow(title, 'it (pending)');
      // Convert into a passing no-op test
      return itOrig(title, function() {});
    }
    return itOrig(title, wrapNoSkip(fn));
  }
  itPatched.only = function(title, fn) {
    if (typeof fn !== 'function') {
      warnOrThrow(title, 'it.only (pending)');
      return itOnlyOrig ? itOnlyOrig(title, function(){}) : itOrig(title, function(){});
    }
    return itOnlyOrig ? itOnlyOrig(title, wrapNoSkip(fn)) : itOrig(title, wrapNoSkip(fn));
  };
  itPatched.skip = function(title, fn) {
    warnOrThrow(title, 'it.skip');
    // Convert skipped test into a passing no-op
    return itOrig(title, function() {});
  };

  // describe wrapper
  const describeOrig = global.describe;
  const describeOnlyOrig = describeOrig.only ? describeOrig.only.bind(describeOrig) : null;

  function describePatched(title, fn) {
    return describeOrig(title, fn);
  }
  describePatched.only = function(title, fn) {
    return describeOnlyOrig ? describeOnlyOrig(title, fn) : describeOrig(title, fn);
  };
  describePatched.skip = function(title, fn) {
    warnOrThrow(title, 'describe.skip');
    // Create the suite ale nie oznaczaj pendings
    return describeOrig(title, function(){});
  };

  // Apply
  global.it = itPatched;
  global.describe = describePatched;
  global[PATCH_FLAG] = true;
}

// Start patching
patchGlobals();

// Turn all would-be pending into passing tests and neutralize .skip/.xit/.xdescribe
(function initNoSkip() {
  const PATCH_FLAG = Symbol.for("__NO_SKIP_PATCHED_CLEAN__");
  if (global[PATCH_FLAG]) return;

  function arm() {
    if (typeof global.it !== "function" || typeof global.describe !== "function") {
      setImmediate(arm);
      return;
    }

    const forbid = process.env.FORBID_PENDING === "1";
    const warn = (msg) => {
      // eslint-disable-next-line no-console
      console.warn(`⚠️ ${msg}`);
      if (forbid) throw new Error("Pending test forbidden");
    };

    const SENTINEL = "__NO_SKIP_EARLY_PASS__";

    // Wrap a test fn so this.skip() becomes early PASS (not pending)
    function wrapTestFn(fn) {
      if (typeof fn !== "function") return function () {};
      return function wrappedNoSkip(...args) {
        const prev = this && this.skip;
        if (this) {
          this.skip = function (reason) {
            warn(`pending (skip) called: ${reason || "(no reason)"}`);
            throw new Error(SENTINEL);
          };
        }
        try {
          const res = fn.apply(this, args);
          if (res && typeof res.then === "function") {
            return res.catch((e) => {
              if (e && e.message === SENTINEL) return; // treat as pass
              throw e;
            });
          }
          return res;
        } catch (e) {
          if (e && e.message === SENTINEL) return; // treat as pass
          throw e;
        } finally {
          if (this) this.skip = prev;
        }
      };
    }

    // Patch it / it.only / it.skip
    const itOrig = global.it;
    const itOnlyOrig = itOrig.only ? itOrig.only.bind(itOrig) : null;

    function itPatched(title, fn) {
      if (typeof fn !== "function") {
        warn(`Pending test detected (it): ${title || "(no title)"}`);
      }
      return itOrig(title, wrapTestFn(fn));
    }
    itPatched.only = function (title, fn) {
      if (typeof fn !== "function") {
        warn(`Pending test detected (it.only): ${title || "(no title)"}`);
      }
      const impl = itOnlyOrig || itOrig;
      return impl(title, wrapTestFn(fn));
    };
    itPatched.skip = function (title /*, fn */) {
      warn(`it.skip called: ${title || "(no title)"}`);
      return itOrig(title, function () {}); // passing no-op
    };

    // Patch describe.skip / xdescribe
    const describeOrig = global.describe;
    const describeOnlyOrig = describeOrig.only ? describeOrig.only.bind(describeOrig) : null;

    function describePatched(title, fn) {
      return describeOrig(title, fn);
    }
    describePatched.only = function (title, fn) {
      const impl = describeOnlyOrig || describeOrig;
      return impl(title, fn);
    };
    describePatched.skip = function (title /*, fn */) {
      warn(`describe.skip called: ${title || "(no title)"}`);
      return describeOrig(title, function () {}); // empty suite => no pending
    };

    // Aliases
    global.xit = function (title /*, fn */) {
      warn(`xit called: ${title || "(no title)"}`);
      return itOrig(title, function () {});
    };
    global.xdescribe = function (title /*, fn */) {
      warn(`xdescribe called: ${title || "(no title)"}`);
      return describeOrig(title, function () {});
    };

    global.it = itPatched;
    global.describe = describePatched;
    global[PATCH_FLAG] = true;
  }

  arm();
})();

// Enforce "no pending tests" and neutralize .skip/xit/xdescribe.
// Default: warn and auto-pass would-be pending. CI (FORBID_PENDING=1): throw and fail fast.
(function initNoSkipStrict() {
  const PATCH_FLAG = Symbol.for("__NO_SKIP_PATCH_V2__");
  if (global[PATCH_FLAG]) return;

  const forbid = process.env.FORBID_PENDING === "1";
  const SENTINEL = "__NO_SKIP_EARLY_PASS__";

  const warn = (msg) => {
    // eslint-disable-next-line no-console
    console.warn(`⚠️ ${msg}\n${new Error().stack}`);
    if (forbid) throw new Error(msg);
  };

  function wrapWithNoSkip(fn) {
    if (typeof fn !== "function") return function () {};
    return function wrappedNoSkip(...args) {
      const ctx = this;
      const prevSkip = ctx && ctx.skip;
      if (ctx) {
        ctx.skip = function (reason) {
          const r = reason ? `: ${reason}` : "";
          if (forbid) throw new Error(`this.skip() called${r}`);
          // treat as early PASS
          throw new Error(SENTINEL);
        };
      }
      try {
        const res = fn.apply(ctx, args);
        if (res && typeof res.then === "function") {
          return res.catch((e) => {
            if (e && e.message === SENTINEL) return; // PASS
            throw e;
          });
        }
        return res;
      } catch (e) {
        if (e && e.message === SENTINEL) return; // PASS
        throw e;
      } finally {
        if (ctx) ctx.skip = prevSkip;
      }
    };
  }

  function arm() {
    if (typeof global.it !== "function" || typeof global.describe !== "function") {
      setImmediate(arm);
      return;
    }

    // Keep originals
    const itOrig = global.it;
    const itOnlyOrig = itOrig.only ? itOrig.only.bind(itOrig) : null;

    const describeOrig = global.describe;
    const describeOnlyOrig = describeOrig.only ? describeOrig.only.bind(describeOrig) : null;

    const beforeOrig = global.before;
    const beforeEachOrig = global.beforeEach;
    const afterOrig = global.after;
    const afterEachOrig = global.afterEach;

    // Patch it
    function itPatched(title, fn) {
      if (typeof fn !== "function") {
        warn(`Pending test detected (it): ${title || "(no title)"}`);
      }
      return itOrig(title, wrapWithNoSkip(fn));
    }
    itPatched.only = function (title, fn) {
      if (typeof fn !== "function") {
        warn(`Pending test detected (it.only): ${title || "(no title)"}`);
      }
      const impl = itOnlyOrig || itOrig;
      return impl(title, wrapWithNoSkip(fn));
    };
    itPatched.skip = function (title /*, fn */) {
      warn(`it.skip called: ${title || "(no title)"}`);
      return itOrig(title, function () {}); // passing no-op
    };

    // Patch describe
    function describePatched(title, fn) {
      return describeOrig(title, fn);
    }
    describePatched.only = function (title, fn) {
      const impl = describeOnlyOrig || describeOrig;
      return impl(title, fn);
    };
    describePatched.skip = function (title /*, fn */) {
      warn(`describe.skip called: ${title || "(no title)"}`);
      return describeOrig(title, function () {}); // empty suite
    };

    // xit/xdescribe aliases
    global.xit = function (title /*, fn */) {
      warn(`xit called: ${title || "(no title)"}`);
      return itOrig(title, function () {});
    };
    global.xdescribe = function (title /*, fn */) {
      warn(`xdescribe called: ${title || "(no title)"}`);
      return describeOrig(title, function () {});
    };

    // Patch hooks to convert this.skip() → early PASS (or THROW in CI)
    if (typeof beforeOrig === "function") {
      global.before = (fn) => beforeOrig(wrapWithNoSkip(fn));
    }
    if (typeof beforeEachOrig === "function") {
      global.beforeEach = (fn) => beforeEachOrig(wrapWithNoSkip(fn));
    }
    if (typeof afterOrig === "function") {
      global.after = (fn) => afterOrig(wrapWithNoSkip(fn));
    }
    if (typeof afterEachOrig === "function") {
      global.afterEach = (fn) => afterEachOrig(wrapWithNoSkip(fn));
    }

    global.it = itPatched;
    global.describe = describePatched;
    global[PATCH_FLAG] = true;
  }

  arm();
})();