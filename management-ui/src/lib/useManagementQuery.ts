/* ============================================================================
   useManagementQuery — thin wrapper over React Query that:
     - fetches via apiClient.get
     - flips OnlineContext offline on NetworkError, online on success
     - never retries (retry:false at the QueryClient level)
   Returns the standard query result; callers normalize collections themselves.
   ========================================================================== */
import { useQuery, type UseQueryResult } from '@tanstack/react-query';
import apiClient, { NetworkError } from './apiClient';
import { useOnline } from '../context/OnlineContext';

export function useManagementQuery<T>(
  path: string,
  options?: { enabled?: boolean; refetchInterval?: number },
): UseQueryResult<T> {
  const { setOffline, setOnline } = useOnline();

  return useQuery<T>({
    queryKey: ['mgmt', path],
    enabled: options?.enabled ?? true,
    refetchInterval: options?.refetchInterval,
    queryFn: async () => {
      try {
        const data = await apiClient.get<T>(path);
        setOnline();
        return data;
      } catch (err) {
        if (err instanceof NetworkError) setOffline();
        throw err;
      }
    },
  });
}
