// Patch happy-dom's cookie handling for Max-Age=0 so that it immediately
// expires the cookie (happy-dom's CookieExpireUtility uses strict < so
// Max-Age=0 sets expires == Date.now() which doesn't satisfy < Date.now()).
let proto = Object.getPrototypeOf(document) as object | null;
while (proto) {
  const desc = Object.getOwnPropertyDescriptor(proto, "cookie");
  if (desc?.set) {
    const orig = desc.set;
    Object.defineProperty(proto, "cookie", {
      get: desc.get,
      set(value: string) {
        const patched = (value as string).replace(
          /Max-Age=0/i,
          "expires=Thu, 01 Jan 1970 00:00:00 GMT"
        );
        orig.call(this, patched);
      },
      configurable: true,
    });
    break;
  }
  proto = Object.getPrototypeOf(proto);
}
