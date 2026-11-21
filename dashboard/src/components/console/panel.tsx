import { SpotlightPanel, StaggerItem } from "@/components/motion/primitives";
import { cn } from "@/lib/utils";

export function Panel({ title, description, action, className, bodyClassName, children, flush }: {
  title?: React.ReactNode;
  description?: React.ReactNode;
  action?: React.ReactNode;
  className?: string;
  bodyClassName?: string;
  children: React.ReactNode;
  /** No body padding, for tables. */
  flush?: boolean;
}) {
  return (
    <StaggerItem className={cn("min-w-0", className)}>
      <SpotlightPanel className="h-full">
        {(title || action) && (
          <div className="flex items-start justify-between gap-3 px-4 pt-3.5 pb-1">
            <div className="min-w-0">
              {title && <h2 className="panel-title text-[13px] font-medium">{title}</h2>}
              {description && <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>}
            </div>
            {action}
          </div>
        )}
        <div className={cn(flush ? "pt-2" : "px-4 pt-2 pb-4", bodyClassName)}>{children}</div>
      </SpotlightPanel>
    </StaggerItem>
  );
}

export function EmptyState({ icon: Icon, title, children }: { icon?: React.ComponentType<{ className?: string }>; title: string; children?: React.ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-6 py-10 text-center">
      {Icon && (
        <div className="grid size-10 place-items-center rounded-lg border bg-faint">
          <Icon className="size-5 text-muted-foreground" />
        </div>
      )}
      <p className="text-sm font-medium">{title}</p>
      {children && <div className="max-w-sm text-xs text-muted-foreground">{children}</div>}
    </div>
  );
}
