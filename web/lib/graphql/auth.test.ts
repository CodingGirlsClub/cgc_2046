import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	SIGN_IN,
	SIGN_UP,
	signUpErrorMessage,
	signInErrorMessage,
	type SignUpResultData,
} from "./auth";

describe("signUp/signIn mutation 文档（对齐 #60 路径 B：httpOnly cookie）", () => {
	it("SIGN_UP 使用 input 嵌套 + result/errors 两段式（无 metadata）", () => {
		const doc = print(SIGN_UP);
		expect(doc).toContain("mutation SignUp($input: SignUpInput!)");
		expect(doc).toContain("signUp(input: $input)");
		expect(doc).toContain("result {");
		expect(doc).toContain("errors {");
		expect(doc).toContain("isPlatformAdmin");
		expect(doc).not.toContain("metadata");
	});

	it("SIGN_IN 使用平铺 email/password 参数 + 平铺返回字段（无 token）", () => {
		const doc = print(SIGN_IN);
		expect(doc).toContain("signIn(email: $email, password: $password)");
		expect(doc).toContain("id");
		expect(doc).toContain("email");
		expect(doc).toContain("isPlatformAdmin");
		expect(doc).not.toContain("token");
	});
});

describe("signUpErrorMessage（signUp 失败走 result.errors）", () => {
	const ok: { signUp: SignUpResultData } = {
		signUp: {
			result: { id: "u1", email: "a@b.c", isPlatformAdmin: false },
			errors: [],
		},
	};

	it("成功时返回 null", () => {
		expect(signUpErrorMessage(ok)).toBeNull();
		expect(signUpErrorMessage(undefined)).toBeNull();
	});

	it("registration_failed（#86 防枚举，重复邮箱与未知错误同形）映射为友好文案", () => {
		const fail: { signUp: SignUpResultData } = {
			signUp: {
				result: null,
				errors: [
					{
						message: "Registration failed. Please check your input and try again.",
						code: "registration_failed",
					},
				],
			},
		};
		expect(signUpErrorMessage(fail)).toBe("注册失败，请检查信息后重试");
	});

	it("非 registration_failed 的 message 直透（如邮箱格式错误，仍可指导用户）", () => {
		const fail: { signUp: SignUpResultData } = {
			signUp: {
				result: null,
				errors: [{ message: "must match the format ...", code: "invalid" }],
			},
		};
		expect(signUpErrorMessage(fail)).toBe("must match the format ...");
	});

	it("errors 为空数组时返回 null（视为成功）", () => {
		const empty: { signUp: SignUpResultData } = {
			signUp: { result: null, errors: [] },
		};
		expect(signUpErrorMessage(empty)).toBeNull();
	});
});

describe("signInErrorMessage（signIn 失败走 Apollo v4 CombinedGraphQLErrors.errors）", () => {
	it("提取认证失败 message（v4 CombinedGraphQLErrors 结构）", () => {
		const e = {
			errors: [
				{ message: "Invalid email or password", code: "authentication_failed" },
			],
		};
		expect(signInErrorMessage(e)).toBe("Invalid email or password");
	});

	it("兼容旧版 ApolloError.graphQLErrors 结构", () => {
		const e = {
			graphQLErrors: [
				{ message: "Invalid email or password", code: "authentication_failed" },
			],
		};
		expect(signInErrorMessage(e)).toBe("Invalid email or password");
	});

	it("v4 错误无数组时回退 message（已 join 各错误文案）", () => {
		const e = { errors: [], message: "Invalid email or password" };
		expect(signInErrorMessage(e)).toBe("Invalid email or password");
	});

	it("非 GraphQL 错误返回 null（由调用方兜底）", () => {
		expect(signInErrorMessage(new Error("network"))).toBeNull();
		expect(signInErrorMessage(undefined)).toBeNull();
		expect(signInErrorMessage(null)).toBeNull();
	});
});
