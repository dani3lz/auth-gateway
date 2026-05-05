import { describe, expect, test } from "bun:test";
import { parseCookies } from "../src/cookies";

describe("parseCookies", () => {
  test("parses a single cookie", () => {
    expect(parseCookies("foo=bar")).toEqual({ foo: "bar" });
  });
  test("parses multiple cookies", () => {
    expect(parseCookies("a=1; b=2; c=3")).toEqual({ a: "1", b: "2", c: "3" });
  });
  test("returns empty object for empty/undefined", () => {
    expect(parseCookies("")).toEqual({});
    expect(parseCookies(undefined)).toEqual({});
  });
  test("URL-decodes values", () => {
    expect(parseCookies("token=abc%20def")).toEqual({ token: "abc def" });
  });
});
