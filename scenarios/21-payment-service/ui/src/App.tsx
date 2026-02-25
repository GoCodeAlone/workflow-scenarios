import { Routes, Route, Navigate } from 'react-router-dom';
import Layout from './components/Layout';
import DashboardPage from './pages/DashboardPage';
import PaymentsPage from './pages/PaymentsPage';
import CapturePage from './pages/CapturePage';
import RefundPage from './pages/RefundPage';
import HealthzPage from './pages/HealthzPage';
import InitDbPage from './pages/InitDbPage';

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Layout />}>
        <Route index element={<DashboardPage />} />
        <Route path="payments" element={<PaymentsPage />} />
        <Route path="capture" element={<CapturePage />} />
        <Route path="refund" element={<RefundPage />} />
        <Route path="healthz" element={<HealthzPage />} />
        <Route path="init-db" element={<InitDbPage />} />
      </Route>
    </Routes>
  );
}
