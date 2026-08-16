import { describe, it, expect } from "vitest";
import { gql } from "@apollo/client";
import { client, httpLinkOptions } from "./apollo-client";

describe("Apollo Client", () => {
	it("uses credentials: same-origin for httpOnly cookie auth", () => {
		expect(httpLinkOptions.credentials).toBe("same-origin");
	});

	it("has an InMemoryCache", () => {
		expect(client.cache).toBeDefined();
	});

	// J1(advisory):双 "c1" 防回归锚——issue 的 checklist item id 只在 issue 内
	// 唯一(R2 纪律),Apollo 默认按 __typename:id 规范化会跨 issue 撞车串数据
	// (E2E F-A 实证:issue2 复用 issue1 的 c1 缓存对象)。本用例经真实
	// InMemoryCache 写入两 issue 各含 "c1" 的响应,断言各自取回自身数据。
	it("keeps duplicate checklist item ids isolated across issues (J1)", () => {
		const QUERY = gql`
			query Detail {
				courseLearningDetail(courseId: "c-1") {
					issues {
						id
						story {
							checklist {
								id
								text
								done
							}
						}
					}
				}
			}
		`;

		const response = {
			courseLearningDetail: {
				__typename: "CourseLearningDetail",
				issues: [
					{
						__typename: "LearningIssue",
						id: "issue-a",
						story: {
							__typename: "IssueStory",
							checklist: [
								{ __typename: "IssueChecklistItem", id: "c1", text: "A 的第一条", done: true },
								{ __typename: "IssueChecklistItem", id: "c2", text: "A 的第二条", done: false },
							],
						},
					},
					{
						__typename: "LearningIssue",
						id: "issue-b",
						story: {
							__typename: "IssueStory",
							checklist: [
								{ __typename: "IssueChecklistItem", id: "c1", text: "B 的第一条(与 A 撞 id)", done: false },
							],
						},
					},
				],
			},
		};

		// 用共享 client.cache:锚定 apollo-client.ts 的真实 typePolicies 配置
		client.cache.restore({});
		client.cache.writeQuery({ query: QUERY, data: response });

		const read = client.cache.readQuery<{ courseLearningDetail: { issues: Array<{ id: string; story: { checklist: Array<{ text: string; done: boolean }> } }> } }>({
			query: QUERY,
		});

		const [issueA, issueB] = read!.courseLearningDetail.issues;
		expect(issueA.story.checklist[0].text).toBe("A 的第一条");
		expect(issueA.story.checklist[0].done).toBe(true);
		// 串台回归形态:policy 失效时此处读到 A 的对象(text/done 均 A 值)
		expect(issueB.story.checklist[0].text).toBe("B 的第一条(与 A 撞 id)");
		expect(issueB.story.checklist[0].done).toBe(false);
	});
});
