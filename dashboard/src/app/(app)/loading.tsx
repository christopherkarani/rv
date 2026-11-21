export default function Loading() {
  return (
    <div aria-busy="true" aria-label="Loading" className="grid gap-3">
      <div className="mb-2 h-3 w-24 rounded skeleton-shimmer" />
      <div className="h-6 w-56 rounded skeleton-shimmer" />
      <div className="mt-3 grid grid-cols-2 gap-3 lg:grid-cols-3 2xl:grid-cols-6">
        {Array.from({ length: 6 }, (_, i) => <div key={i} className="h-[116px] rounded-xl border skeleton-shimmer" />)}
      </div>
      <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_380px]">
        <div className="h-[380px] rounded-xl border skeleton-shimmer" />
        <div className="h-[380px] rounded-xl border skeleton-shimmer" />
      </div>
    </div>
  );
}
