import { ApolloClient, InMemoryCache, createHttpLink } from "@apollo/client";

/**
 * Apollo Client 实例。
 *
 * 认证 token 由后端通过 httpOnly cookie 交付（#60 路径 B），浏览器自动随同源请求携带。
 * 前端不再持有 token、不再拼 Authorization 头。
 */

// ponytail: 提取为命名常量以便测试断言 credentials 值
export const httpLinkOptions = {
	uri: process.env.NEXT_PUBLIC_GRAPHQL_URL ?? "/api/graphql",
	credentials: "same-origin" as const,
};

const httpLink = createHttpLink(httpLinkOptions);

export const client = new ApolloClient({
	link: httpLink,
	cache: new InMemoryCache(),
});
