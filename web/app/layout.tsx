import type { Metadata } from "next";
import { connection } from "next/server";
import { Inter, Geist_Mono } from "next/font/google";
import ApolloWrapper from "./apollo-provider";
import ThemeProvider from "@/lib/theme-provider";
import ThemeSync from "@/lib/theme-sync";
import "./globals.css";

// Linear 设计系统默认字体（Inter）；mono 沿用 Geist Mono。
const inter = Inter({
	variable: "--font-inter",
	subsets: ["latin"],
	display: "swap",
});

const geistMono = Geist_Mono({
	variable: "--font-geist-mono",
	subsets: ["latin"],
});

export const metadata: Metadata = {
	title: "CGC 2046",
	description:
		"Coding Girls Club（程序媛汇）：从 2016 到 2046，陪一代女性走进编程的公益编程社群。",
};

export default async function RootLayout({
	children,
}: Readonly<{
	children: React.ReactNode;
}>) {
	await connection();
	return (
		<html
			lang="zh-CN"
			className={`${inter.variable} ${geistMono.variable} h-full antialiased`}
		>
			<body className="min-h-full flex flex-col">
				<ThemeProvider>
					<ApolloWrapper>
						<ThemeSync />
						{children}
					</ApolloWrapper>
				</ThemeProvider>
			</body>
		</html>
	);
}
