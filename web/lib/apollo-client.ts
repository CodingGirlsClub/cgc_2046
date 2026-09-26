import { ApolloClient, InMemoryCache, ApolloLink } from "@apollo/client";
import { HttpLink } from "@apollo/client/link/http";
import { RemoveTypenameFromVariablesLink } from "@apollo/client/link/remove-typename";

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

const httpLink = new HttpLink(httpLinkOptions);

// 缓存对象直接作为 input 变量发出时（圈选区间、雾区间等），Apollo 会带上
// __typename，后端 Absinthe 按 input 类型校验直接拒收（「Unknown field」，
// M1 浏览器实测）。出站前统一剥掉，整类问题收口在这里。
const link = ApolloLink.from([new RemoveTypenameFromVariablesLink(), httpLink]);

export const client = new ApolloClient({
	link,
	cache: new InMemoryCache({
		typePolicies: {
			// U8(#180):issue 的 checklist item id 只在 issue 内唯一(R2 id 纪律,
			// 如两张卡各有 "c1")——Apollo 默认按 __typename:id 规范化会跨 issue
			// 撞车串数据(E2E 实证:issue2 复用了 issue1 的 c1 缓存对象)。
			// 内嵌列表禁用规范化键,按属主 issue 逐次取响应。
			IssueChecklistItem: { keyFields: false },
			// materials 同理:朴素参考列表,issue 内语义、无全局唯一 id
			IssueMaterial: { keyFields: false },
			// S8（ADR-0011 §B#22）:objective id/title 是课程内容内字符串 id,非全局
			// 唯一——按 __typename:id 规范化会跨课程/跨 run 串掌握态(同型事故先例)
			LearningObjectiveState: { keyFields: false },
			// prerequisites 引用条目同理(缺先修 title 展示)
			LearningPrereqRef: { keyFields: false },
		},
	}),
});
