import { redirect } from "@/i18n/navigation";

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export default async function RegisterPage({ params, searchParams }: PageProps) {
  const { locale } = await params;
  const next = (await searchParams)?.next;
  // Fixed local destination. Final next navigation uses the existing same-origin validator.
  redirect({ href: typeof next === "string" && next ? { pathname: "/login", query: { next } } : "/login", locale });
}
