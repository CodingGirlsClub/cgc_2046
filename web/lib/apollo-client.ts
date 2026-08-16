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
	cache: new InMemoryCache({
		typePolicies: {
			// U8(#180):issue 的 checklist item id 只在 issue 内唯一(R2 id 纪律,
			// 如两张卡各有 "c1")——Apollo 默认按 __typename:id 规范化会跨 issue
			// 撞车串数据(E2E 实证:issue2 复用了 issue1 的 c1 缓存对象)。
			// 内嵌列表禁用规范化键,按属主 issue 逐次取响应。
			IssueChecklistItem: { keyFields: false },
			// materials 同理:朴素参考列表,issue 内语义、无全局唯一 id
			IssueMaterial: { keyFields: false },
		},
	}),
});
