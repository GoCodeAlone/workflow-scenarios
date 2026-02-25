import { Routes, Route, Navigate } from 'react-router-dom';
import Layout from './components/Layout';
import DashboardPage from './pages/DashboardPage';
import OrdersPage from './pages/OrdersPage';
import ProductsPage from './pages/ProductsPage';
import HealthzPage from './pages/HealthzPage';
import InitDbPage from './pages/InitDbPage';
import PaymentPage from './pages/PaymentPage';

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Layout />}>
        <Route index element={<DashboardPage />} />
        <Route path="orders" element={<OrdersPage />} />
        <Route path="products" element={<ProductsPage />} />
        <Route path="healthz" element={<HealthzPage />} />
        <Route path="init-db" element={<InitDbPage />} />
        <Route path="payment" element={<PaymentPage />} />
      </Route>
    </Routes>
  );
}
