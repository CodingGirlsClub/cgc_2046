import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
	MY_PHONE,
	SIGN_IN,
	SIGN_UP_WITH_PHONE,
	UPDATE_MY_PHONE,
	signInErrorMessage,
} from "./auth";

describe("signUpWithPhone/signIn mutation 文档（httpOnly cookie；邮箱 signUp 已下线）", () => {
	it("SIGN_UP_WITH_PHONE 使用 input 嵌套 + result/errors 两段式（无 metadata）", () => {
		const doc = print(SIGN_UP_WITH_PHONE);
		expect(doc).toContain("mutation SignUpWithPhone($input: SignUpWithPhoneInput!)");
		expect(doc).toContain("signUpWithPhone(input: $input)");
		expect(doc).toContain("result {");
		expect(doc).toContain("errors {");
		expect(doc).toContain("isPlatformAdmin");
		expect(doc).not.toContain("metadata");
	});

	it("SIGN_IN 使用平铺 login/password 参数（手机号/邮箱单框）+ 平铺返回字段（无 token）", () => {
		const doc = print(SIGN_IN);
		expect(doc).toContain("signIn(login: $login, password: $password)");
		expect(doc).toContain("id");
		expect(doc).toContain("email");
		expect(doc).toContain("isPlatformAdmin");
		expect(doc).not.toContain("token");
	});
});

describe("myPhone/updateMyPhone 文档（设置页绑定/换绑手机号，purpose CHANGE_PHONE）", () => {
	it("MY_PHONE：无变量 query MyPhone，选择集仅掩码标量 myPhone", () => {
		const doc = print(MY_PHONE);
		expect(doc).toContain("query MyPhone");
		expect(doc).toContain("myPhone");
		expect(doc).not.toContain("$");
		expect(doc).not.toContain("mutation");
	});

	it("UPDATE_MY_PHONE：平铺 phone/code 非空变量 + updateMyPhone 选择集 id", () => {
		const doc = print(UPDATE_MY_PHONE);
		expect(doc).toContain(
			"mutation UpdateMyPhone($phone: String!, $code: String!)",
		);
		expect(doc).toContain("updateMyPhone(phone: $phone, code: $code)");
		expect(doc).toContain("id");
		expect(doc).not.toContain("errors {");
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
