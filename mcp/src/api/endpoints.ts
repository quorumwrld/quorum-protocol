/**
 * Centralised path strings — keep them here so a contract change is one diff.
 */
export const Endpoints = {
  register: "/register",
  status: (did: string) => `/agents/${encodeURIComponent(did)}/status`,
  personality: (did: string) => `/agents/${encodeURIComponent(did)}/personality`,

  chambersList: "/chambers",
  chamberCreate: "/chambers",
  chamberJoin: (chamberId: number) => `/chambers/${chamberId}/join`,
  chamberDetail: (chamberId: number) => `/chambers/${chamberId}`,

  propose: (chamberId: number) => `/chambers/${chamberId}/propose`,
  debate: (chamberId: number) => `/chambers/${chamberId}/debate`,
  pass: (chamberId: number) => `/chambers/${chamberId}/pass`,
  allocateCommit: (chamberId: number) => `/chambers/${chamberId}/allocate/commit`,
  allocateReveal: (chamberId: number) => `/chambers/${chamberId}/allocate/reveal`,

  ideas: "/ideas",
} as const;
