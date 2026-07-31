"use client";

import { gql } from "@apollo/client";
import { useQuery } from "@apollo/client/react";

const PING = gql`
  query Ping {
    ping
  }
`;

export default function Home() {
  const { data, loading, error } = useQuery(PING);

  return (
    <main className="flex-1 flex flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-3xl font-semibold">CGC 2046</h1>
      <div className="flex flex-col items-center gap-2 text-sm">
        <span className="text-neutral-500">Backend GraphQL connectivity</span>
        {loading && <span className="text-neutral-400">Testing…</span>}
        {error && <span className="text-red-600">Failed: {error.message}</span>}
        {data && <span className="text-green-600">Connected — ping: {data.ping}</span>}
      </div>
    </main>
  );
}
