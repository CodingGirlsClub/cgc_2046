export type Mode = "voices" | "wishes";
export type City = "北京" | "上海" | "杭州" | "成都" | "广州";
export type Entry = { id: string; city: City; text: string; author: string; year: number; count: number; echo?: string; mine?: boolean };
export const CITIES: { name: City; lng: number; lat: number; label: string }[] = [
	{ name: "北京", lng: 116.4074, lat: 39.9042, label: "一座城，一些勇敢的开始" },
	{ name: "上海", lng: 121.4737, lat: 31.2304, label: "让好奇心，沿江生长" },
	{ name: "杭州", lng: 120.1551, lat: 30.2741, label: "愿下一次相遇，仍有新意" },
	{ name: "成都", lng: 104.0665, lat: 30.5723, label: "山河很远，彼此很近" },
	{ name: "广州", lng: 113.2644, lat: 23.1291, label: "微小的开始，也有回声" },
];
export const QUOTES: Entry[] = [
	{ id: "q1", city: "北京", text: "我想成为一个，敢说「我不会，但我可以学」的人。", author: "王**", year: 2014, count: 32 },
	{ id: "q2", city: "上海", text: "原来我也可以，是改变的开始。", author: "林晓", year: 2016, count: 46 },
	{ id: "q3", city: "广州", text: "我想亲手做出一个，妈妈也会用的网站。", author: "陈**", year: 2013, count: 18 },
	{ id: "q4", city: "成都", text: "不想再只做一个使用者，我想成为创造者。", author: "李**", year: 2015, count: 27 },
	{ id: "q5", city: "杭州", text: "希望十年后的我，还保留着今天的好奇心。", author: "张**", year: 2012, count: 39 },
	{ id: "q6", city: "北京", text: "我不是最勇敢的那个，但今天我来了。", author: "刘**", year: 2014, count: 21 },
	{ id: "q7", city: "上海", text: "转行不是重新开始，是终于开始。", author: "赵**", year: 2017, count: 24 },
	{ id: "q8", city: "成都", text: "想和一群相信可能的人，做一点不一样的事。", author: "周**", year: 2018, count: 16 },
	{ id: "q9", city: "杭州", text: "写下第一行代码时，我听见了一扇门打开。", author: "苏晴", year: 2016, count: 35 },
	{ id: "q10", city: "广州", text: "世界很大，我想多一种认识它的语言。", author: "吴**", year: 2015, count: 12 },
	{ id: "q11", city: "北京", text: "如果没有标准答案，那我就试着写一个。", author: "郑**", year: 2013, count: 9 },
	{ id: "q12", city: "成都", text: "我想把「不可能」后面的句号，改成逗号。", author: "孙**", year: 2018, count: 6 },
];
export const WISHES: Entry[] = [
	{ id: "w1", city: "北京", text: "想再参加一次，零基础也能来的编程工作坊。", author: "林**", year: 2026, count: 28, echo: "北京 · 周末编程工作坊" },
	{ id: "w2", city: "上海", text: "想和转行的女生们，聊聊开始之后的生活。", author: "赵**", year: 2026, count: 19 },
	{ id: "w3", city: "杭州", text: "想认识更多女性开发者，一起做一点小东西。", author: "苏晴", year: 2026, count: 23, echo: "杭州 · 女生的周末共创日" },
	{ id: "w4", city: "成都", text: "和女生一起，做一个真正能用的小作品。", author: "周**", year: 2026, count: 17 },
	{ id: "w5", city: "广州", text: "希望能带着妈妈，来上一堂编程课。", author: "陈**", year: 2026, count: 11 },
	{ id: "w6", city: "北京", text: "想知道当年的伙伴，现在都在创造什么。", author: "王**", year: 2026, count: 14 },
];
export const STAGES = [
	{ name: "源起", text: "一束微光，从这里出发。", at: 0.05 },
	{ name: "流向远方", text: "沿着山河，抵达更多人的生活。", at: 0.34 },
	{ name: "山河渐醒", text: "光走过的地方，开始有了颜色。", at: 0.64 },
	{ name: "天光满树", text: "那些微小的开始，照亮了这一刻。", at: 1 },
];
