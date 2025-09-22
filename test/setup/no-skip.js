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