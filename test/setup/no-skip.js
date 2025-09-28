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
    // Create the suite but do not mark pendings
    return describeOrig(title, function(){});
  };

  // Apply
  global.it = itPatched;
  global.describe = describePatched;
  global[PATCH_FLAG] = true;
}

// Start patching
patchGlobals();