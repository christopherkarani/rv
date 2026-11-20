import { DownloadIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { PageBody, PageHeader } from "@/components/shared"
import { ActivityFeed } from "./activity-feed"

export default function ActivityPage() {
  return (
    <>
      <PageHeader
        title="Activity"
        description="Every deny, would-be deny, override and alert forwarded by rv audit forward. Rule ids only, never command text."
        actions={
          <>
            <Button variant="outline">
              <DownloadIcon />
              Export OCSF
            </Button>
          </>
        }
      />
      <PageBody>
        <ActivityFeed />
      </PageBody>
    </>
  )
}
