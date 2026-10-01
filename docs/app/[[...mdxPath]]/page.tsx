import { generateStaticParamsFor, importPage } from 'nextra/pages'
import { useMDXComponents } from '../../mdx-components'

export const generateStaticParams = generateStaticParamsFor('mdxPath')

type Props = { params: Promise<{ mdxPath?: string[] }> }

export async function generateMetadata(props: Props) {
  const { mdxPath } = await props.params
  const { metadata } = await importPage(mdxPath)
  // The landing page keeps the site title instead of "Cheeto – Cheeto"
  return mdxPath ? metadata : { ...metadata, title: { absolute: 'Cheeto: typed, secure networking for Roblox' } }
}

const Wrapper = useMDXComponents().wrapper

export default async function Page(props: Props) {
  const params = await props.params
  const { default: MDXContent, toc, metadata, sourceCode } = await importPage(params.mdxPath)
  return (
    <Wrapper toc={toc} metadata={metadata} sourceCode={sourceCode}>
      {/* Doc typography is scoped to this wrapper so it stays off the landing page */}
      {params.mdxPath ? (
        <div className="cheeto-content">
          <MDXContent {...props} params={params} />
        </div>
      ) : (
        <MDXContent {...props} params={params} />
      )}
    </Wrapper>
  )
}
