/* Ethers v6 <-> v5 compatibility shim for tests */

const { Contract } = require("ethers");

// 1) Alias .address -> .target (ethers v6)
try {
  if (!Object.getOwnPropertyDescriptor(Contract.prototype, "address")) {
    Object.defineProperty(Contract.prototype, "address", {
      get: function () {
        return this.target || this._address || undefined;
      },
      configurable: true,
    });
  }
} catch (_) {}

// 2) BigInt helpers, by test calls like x.sub(y)
function toBigInt(x) {
  if (typeof x === "bigint") return x;
  if (x == null) throw new TypeError("Cannot convert null/undefined to bigint");
  return BigInt(x.toString());
}
function addBigIntMethod(name, fn) {
  const proto = BigInt.prototype;
  if (!Object.prototype.hasOwnProperty.call(proto, name)) {
    Object.defineProperty(proto, name, {
      value: fn,
      writable: false,
      enumerable: false,
      configurable: true,
    });
  }
}
addBigIntMethod("add", function (x) { return this + toBigInt(x); });
addBigIntMethod("sub", function (x) { return this - toBigInt(x); });
addBigIntMethod("mul", function (x) { return this * toBigInt(x); });
addBigIntMethod("div", function (x) { return this / toBigInt(x); });
addBigIntMethod("mod", function (x) { return this % toBigInt(x); });

addBigIntMethod("eq", function (x) { return this === toBigInt(x); });
addBigIntMethod("lt", function (x) { return this < toBigInt(x); });
addBigIntMethod("lte", function (x) { return this <= toBigInt(x); });
addBigIntMethod("gt", function (x) { return this > toBigInt(x); });
addBigIntMethod("gte", function (x) { return this >= toBigInt(x); });

addBigIntMethod("toHexString", function () {
  const hex = this.toString(16);
  return "0x" + (hex.length % 2 === 1 ? "0" + hex : hex);
});